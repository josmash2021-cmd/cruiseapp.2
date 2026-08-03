import 'dart:async';
import '../utils/app_platform.dart';
import '../utils/vehicle_tier_style.dart';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';
import '../config/mapbox_config.dart';
import '../config/route_observers.dart';
import '../map/map_surface_coordinator.dart';
import '../map/web_map_view.dart';
import '../config/map_theme.dart';
import 'package:intl/intl.dart';

import '../config/api_keys.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../config/map_styles.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/directions_service.dart';
import '../services/local_data_service.dart';
import '../services/notification_service.dart';
import '../services/places_service.dart';
import '../services/screen_security_service.dart';
import '../services/trip_firestore_service.dart';
import '../services/user_session.dart';
import '../utils/app_toast.dart';
import '../utils/mapbox_safe.dart';
import '../services/map_controller_cache.dart';
import 'airport_terminal_sheet.dart';
import 'payment_accounts_screen.dart';
import 'ride_booking_confirmed_screen.dart';
import '../widgets/map/circular_pin_renderer.dart';
import '../widgets/neu_style.dart';

class ScheduleBookingScreen extends StatefulWidget {
  final DateTime scheduledAt;

  const ScheduleBookingScreen({super.key, required this.scheduledAt});

  @override
  State<ScheduleBookingScreen> createState() => _ScheduleBookingScreenState();
}

class _ScheduleBookingScreenState extends State<ScheduleBookingScreen>
    with TickerProviderStateMixin, SecureScreenMixin, RouteAware {
  /// Identifies this screen to [MapSurfaceCoordinator].
  ///
  /// This screen opens the location picker, which has a full-screen map of
  /// its own. Ours stayed mounted underneath — two live Mapbox surfaces,
  /// which closes the app on iOS.
  static const String _mapSurfaceOwner = 'ScheduleBooking';
  bool _mapMounted = false;

  static const _gold = Color(0xFFE8C547);
  static final _hourRe = RegExp(r'(\d+)\s*(h|hr|hrs|hour|hours)');
  static final _minRe = RegExp(r'(\d+)\s*(m|min|mins|minute|minutes)');
  static final _digitRe = RegExp(r'(\d+)');
  static final _milesCleanRe = RegExp(r'[^\d.]');
  static final _durCleanRe = RegExp(r'[^\d]');
  // Map center — starts at rider GPS, falls back to central Florida
  // (service area: State of Florida; refine per launch market)
  LatLng _mapCenter = const LatLng(28.0, -82.4);

  final _places = PlacesService(ApiKeys.webServices);
  final _directions = DirectionsService(ApiKeys.webServices);

  final _pickupCtrl = TextEditingController();
  final _dropoffCtrl = TextEditingController();
  final _pickupFocus = FocusNode();
  final _dropoffFocus = FocusNode();

  // Addresses
  String _pickupAddress = '';
  String _dropoffAddress = '';
  LatLng? _pickupLatLng;
  LatLng? _dropoffLatLng;

  // Autocomplete
  List<PlaceSuggestion> _suggestions = [];
  bool _searchingPickup = false;
  Timer? _debounce;
  bool _showSuggestions = false;

  // Map
  mapbox.MapboxMap? _mapCtrl;
  // Web counterpart — GL JS surface behind the kIsWeb guard below.
  WebMapController? _webMapCtrl;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PolylineAnnotationManager? _polylineAnnotMgr;
  List<mapbox.PointAnnotation> _markerAnnots = [];
  mapbox.PolylineAnnotation? _routeAnnot;
  bool _mapReady = false;

  // ── Cinematic animation ──
  AnimationController? _tiltCtrl;
  Animation<double>? _tiltAnim;
  AnimationController? _bearingCtrl;
  Animation<double>? _bearingAnim;
  double _cinematicPitch = 0;
  double _cinematicBearing = 0;
  bool _cinematicDone = false;
  Ticker? _routeDrawTicker;

  // Route
  String _tripMiles = '';
  String _tripDuration = '';
  bool _routeLoaded = false;

  // Ride options
  int _selectedRide = 0;
  List<_RideOption> _rides = [];

  // Payment
  String _selectedPaymentMethod = AppPlatform.isIOS ? 'apple_pay' : 'google_pay';
  Set<String> _linkedPaymentMethods = {};
  String? _savedCardLast4;
  String? _savedCardBrand;

  // Airport
  AirportSelection? _airportSelection;

  // State
  bool _isBooking = false;
  bool _isLoadingRoute = false;

  // Pre-rendered gold teardrop pin bytes
  Uint8List? _pickupPinBytes;
  Uint8List? _dropoffPinBytes;

  @override
  void initState() {
    super.initState();
    unawaited(_acquireMapSurface());
    _loadPayments();
    _rides = _defaultRides();
    _pickupFocus.addListener(_onPickupFocusChanged);
    _dropoffFocus.addListener(_onDropoffFocusChanged);
    _buildPinBytes();
    _resolveGpsCenter();
  }

  /// Get rider's real-time GPS, center the map, and fill pickup with real address.
  Future<void> _resolveGpsCenter() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 5));
      final loc = LatLng(pos.latitude, pos.longitude);
      _mapCenter = loc;
      // Reverse geocode to get the real street address for the pickup field
      final address = await _places
          .reverseGeocode(lat: pos.latitude, lng: pos.longitude)
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      if (address != null && address.isNotEmpty && _pickupAddress.isEmpty) {
        setState(() {
          _pickupAddress = address;
          _pickupCtrl.text = address;
          _pickupLatLng = loc;
        });
      }
      // Fly the map to the GPS location
      if (_mapCtrl != null) {
        _mapCtrl!.flyTo(
          mapbox.CameraOptions(
            center: mapbox.Point(coordinates: mapbox.Position(loc.longitude, loc.latitude)),
            zoom: 14.0,
          ),
          mapbox.MapAnimationOptions(duration: 800),
        );
      }
    } catch (_) {
      // Keep default center
    }
  }

  Future<void> _buildPinBytes() async {
    _pickupPinBytes = await renderCircularPinBytes(icon: CircularPinIcon.dot, isPickup: true, radius: 32);
    _dropoffPinBytes = await renderCircularPinBytes(icon: CircularPinIcon.flag, isPickup: false, radius: 32);
  }

  void _onPickupFocusChanged() => setState(() {});
  void _onDropoffFocusChanged() => setState(() {});

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
        setState(() => _mapMounted = false);
        await surfaceRemoved();
      },
    );
    if (!mounted) {
      MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
      return;
    }
    setState(() => _mapMounted = true);
  }

  /// Back from the picker — take the surface back.
  @override
  void didPopNext() {
    if (!mounted || _mapMounted) return;
    unawaited(_acquireMapSurface());
  }

  @override
  void dispose() {
    mapRouteObserver.unsubscribe(this);
    MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
    _debounce?.cancel();
    _pickupFocus.removeListener(_onPickupFocusChanged);
    _dropoffFocus.removeListener(_onDropoffFocusChanged);
    _pickupCtrl.dispose();
    _dropoffCtrl.dispose();
    _pickupFocus.dispose();
    _dropoffFocus.dispose();
    _routeDrawTicker?.dispose();
    _tiltCtrl?.dispose();
    _bearingCtrl?.dispose();
    _mapCtrl?.dispose();
    super.dispose();
  }

  /// Maps ride name to Cruise-branded car image asset.
  ///
  /// A fourth copy of this table used to live here, keyed on substrings
  /// of the ride's display name and reaching for a third set of photos.
  /// A rider scheduling a Premium saw one car and a rider booking the
  /// same Premium now saw another.
  static String _rideCarAsset(String name) => tierCarImage(name);

  /// Accent color per ride type.
  static Color _rideAccentColor(String name) {
    final n = name.toLowerCase();
    if (n.contains('vip')) return const Color(0xFFD4AF37);
    if (n.contains('comfort')) return const Color(0xFF2ECC71);
    return Colors.white;
  }

  /// Badge info: (label, icon, bgColor, textColor)
  static (String, IconData, Color, Color) _rideBadgeInfo(String name) {
    final n = name.toLowerCase();
    if (n.contains('vip')) return ('VIP', Icons.star_rounded, const Color(0xFFD4AF37), Colors.black);
    if (n.contains('comfort')) return ('COMFORT', Icons.eco_rounded, const Color(0xFF1A3A2A), const Color(0xFF2ECC71));
    return ('PREMIUM', Icons.diamond_rounded, const Color(0xFF2A2F45), Colors.white);
  }

  /// Card description per ride type.
  static String _rideDescription(String name) {
    final n = name.toLowerCase();
    if (n.contains('vip')) return 'Luxury SUV with premium amenities';
    if (n.contains('comfort')) return 'Reliable ride at great value';
    return 'Elegant sedan for any occasion';
  }

  /// Card features per ride type.
  static String _rideFeatures(String name) {
    final n = name.toLowerCase();
    if (n.contains('vip')) return 'Spacious • Leather • Snacks & Drinks';
    if (n.contains('comfort')) return 'Clean • Safe • Efficient';
    return 'Comfort • Climate • Charger';
  }

  List<_RideOption> _defaultRides() => [
    _RideOption(
      name: 'VIP',
      vehicle: 'Suburban',
      price: '\$--',
      eta: '--',
      promoted: true,
    ),
    _RideOption(name: 'Premium', vehicle: 'Camry', price: '\$--', eta: '--'),
    _RideOption(name: 'Comfort', vehicle: 'Fusion', price: '\$--', eta: '--'),
  ];

  Future<void> _loadPayments() async {
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

  // ── Autocomplete ────────────────────────────────────────────────────

  void _onPickupChanged(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 320), () async {
      final results = await _places.autocomplete(
        q,
        latitude: _pickupLatLng?.latitude ?? _mapCenter.latitude,
        longitude: _pickupLatLng?.longitude ?? _mapCenter.longitude,
      );
      if (!mounted) return;
      setState(() {
        _suggestions = results;
        _searchingPickup = true;
        _showSuggestions = true;
      });
    });
  }

  void _onDropoffChanged(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 320), () async {
      final results = await _places.autocomplete(
        q,
        latitude: _pickupLatLng?.latitude ?? _mapCenter.latitude,
        longitude: _pickupLatLng?.longitude ?? _mapCenter.longitude,
      );
      if (!mounted) return;
      setState(() {
        _suggestions = results;
        _searchingPickup = false;
        _showSuggestions = true;
      });
    });
  }

  Future<void> _onSelectSuggestion(PlaceSuggestion s) async {
    final details = await _places.geocodeAddress(s.description);
    if (!mounted) return;
    final latLng = details != null ? LatLng(details.lat, details.lng) : null;
    setState(() {
      _showSuggestions = false;
      _suggestions = [];
      if (_searchingPickup) {
        _pickupAddress = s.description;
        _pickupCtrl.text = s.description;
        _pickupLatLng = latLng;
        _pickupFocus.unfocus();
        if (_dropoffCtrl.text.trim().isEmpty) _dropoffFocus.requestFocus();
      } else {
        _dropoffAddress = s.description;
        _dropoffCtrl.text = s.description;
        _dropoffLatLng = latLng;
        _dropoffFocus.unfocus();
      }
    });
    _places.resetSession();
    if (kIsWeb) _refreshWebMap();
    _tryFetchRoute();
  }

  // ── Route ────────────────────────────────────────────────────────────

  Future<void> _tryFetchRoute() async {
    if (_pickupLatLng == null || _dropoffLatLng == null) return;
    setState(() {
      _isLoadingRoute = true;
      _routeLoaded = false;
    });
    try {
      final route = await _directions.getRoute(
        origin: _pickupLatLng!,
        destination: _dropoffLatLng!,
      );
      if (!mounted) return;
      if (route != null) {
        final miles = route.distanceMeters / 1609.34;
        final dur = route.durationText;
        setState(() {
          _tripMiles = '${miles.toStringAsFixed(1)} mi';
          _tripDuration = dur;
          _routeLoaded = true;
          _updateRidePricing(dur);
        });
        _startCinematicRoute(route.points);
        _fitMap();
        if (kIsWeb) _refreshWebMap(route.points);
      }
    } catch (_) {}
    if (mounted) setState(() => _isLoadingRoute = false);
  }

  Future<void> _updateMapAnnotations(List<LatLng> routePoints) async {
    final pointMgr = _pointAnnotMgr;
    final polyMgr = _polylineAnnotMgr;
    if (pointMgr == null || polyMgr == null) return;
    // Clear previous
    for (final a in _markerAnnots) { try { await pointMgr.delete(a); } catch (_) {} }
    _markerAnnots = [];
    if (_routeAnnot != null) { try { await polyMgr.delete(_routeAnnot!); } catch (_) {} _routeAnnot = null; }
    // Pickup marker — gold teardrop with person icon
    if (_pickupLatLng != null && _pickupPinBytes != null) {
      final pickupPoint = safePoint(_pickupLatLng!.longitude, _pickupLatLng!.latitude);
      if (pickupPoint != null) {
        final a = await pointMgr.create(mapbox.PointAnnotationOptions(
          geometry: pickupPoint,
          image: _pickupPinBytes!,
          iconSize: 1.0,
          iconAnchor: mapbox.IconAnchor.BOTTOM,
        ));
        _markerAnnots.add(a);
      }
    }
    // Dropoff marker — gold teardrop with destination icon
    if (_dropoffLatLng != null && _dropoffPinBytes != null) {
      final dropoffPoint = safePoint(_dropoffLatLng!.longitude, _dropoffLatLng!.latitude);
      if (dropoffPoint != null) {
        final a = await pointMgr.create(mapbox.PointAnnotationOptions(
          geometry: dropoffPoint,
          image: _dropoffPinBytes!,
          iconSize: 1.0,
          iconAnchor: mapbox.IconAnchor.BOTTOM,
        ));
        _markerAnnots.add(a);
      }
    }
  }

  /// Cinematic route reveal: fit → tilt 55° + bearing → 4-layer gold draw → glow
  Future<void> _startCinematicRoute(List<LatLng> routePoints) async {
    // Cap route endpoints to exact pin coordinates so polyline meets the pins
    if (routePoints.length >= 2 && _pickupLatLng != null && _dropoffLatLng != null) {
      routePoints = List.of(routePoints);
      routePoints[0] = _pickupLatLng!;
      routePoints[routePoints.length - 1] = _dropoffLatLng!;
    }
    // Place markers first
    await _updateMapAnnotations(routePoints);
    if (!mounted || routePoints.length < 2) return;

    // Stop previous
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = null;

    // 1. Wait for fit (handled by _fitMap caller)
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;

    // 2. Tilt 0° → 30° + random bearing (1200ms)
    final rng = math.Random();
    final degrees = 5.0 + rng.nextDouble() * 10.0;
    final randomBearing = degrees * (rng.nextBool() ? 1.0 : -1.0);

    _tiltCtrl?.dispose();
    _tiltCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _tiltAnim = Tween<double>(begin: 0.0, end: 30.0).animate(
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

    // 3. Gold route draw 500ms into tilt
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    await _animateGoldRoute(routePoints);
    if (!mounted) return;

    // 4. Save camera state
    _cinematicPitch = 30.0;
    _cinematicBearing = randomBearing;
    _cinematicDone = true;
  }

  void _applyCinematicCamera() {
    if (_mapCtrl == null || !mounted) return;
    _mapCtrl!.setCamera(mapbox.CameraOptions(
      pitch: _tiltAnim?.value,
      bearing: _bearingAnim?.value,
    ));
  }

  Future<void> _animateGoldRoute(List<LatLng> points) async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null || points.length < 2) return;

    // Pre-create annotation before ticker to avoid async frame skipping
    if (_routeAnnot != null) { try { await polyMgr.delete(_routeAnnot!); } catch (_) {} _routeAnnot = null; }
    final routeGeo = safeLineString(points.sublist(0, 2));
    if (routeGeo == null) return;
    try { _routeAnnot = await polyMgr.create(mapbox.PolylineAnnotationOptions(
      geometry: routeGeo,
      lineColor: const Color(0xFFFFD700).toARGB32(), lineWidth: 5.0, lineJoin: mapbox.LineJoin.ROUND,
    )); } catch (_) {}
    if (!mounted || _routeAnnot == null) return;

    final totalMs = (points.length * 10).clamp(1800, 3500);
    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    int lastCount = 2;
    bool updating = false;

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
        if (!completer.isCompleted) completer.complete();
      }
    });
    _routeDrawTicker!.start();
    return completer.future;
  }

  void _updateRidePricing(String durationText) {
    final baseMin = _durationToMinutes(durationText);
    final vipMin = (baseMin * 0.85).ceil().clamp(1, 300);
    final premMin = baseMin;
    final comMin = (baseMin * 1.10).ceil().clamp(1, 300);
    final comMax = (baseMin * 1.45).ceil().clamp(comMin, 300);
    setState(() {
      _rides = [
        _RideOption(
          name: 'VIP',
          vehicle: 'Suburban',
          price: _price(vipMin, 2.2),
          eta: '$vipMin min',
          promoted: true,
        ),
        _RideOption(
          name: 'Premium',
          vehicle: 'Camry',
          price: _price(premMin, 1.35),
          eta: '$premMin min',
        ),
        _RideOption(
          name: 'Comfort',
          vehicle: 'Fusion',
          price: _price(comMax, 0.92),
          eta: '$comMin-$comMax min',
        ),
      ];
    });
  }

  int _durationToMinutes(String v) {
    final lower = v.toLowerCase();
    final h = _hourRe.firstMatch(lower);
    final m = _minRe.firstMatch(lower);
    var mins = 0;
    if (h != null) mins += (int.tryParse(h.group(1) ?? '') ?? 0) * 60;
    if (m != null) {
      mins += int.tryParse(m.group(1) ?? '') ?? 0;
    } else {
      final n = _digitRe.firstMatch(lower);
      if (n != null) mins += int.tryParse(n.group(1) ?? '') ?? 0;
    }
    return mins.clamp(1, 300);
  }

  String _price(int minutes, double mult) {
    final v = (minutes / 60.0) * 120.0 * mult;
    return '\$${v.toStringAsFixed(2)}';
  }

  /// Web counterpart of the native annotation/fit path: same gold route and
  /// pickup/dropoff pins on the GL JS surface. The cinematic tilt is skipped.
  void _refreshWebMap([List<LatLng>? routePoints]) {
    final c = _webMapCtrl;
    if (c == null) return;
    c.clearMarkers();
    if (_pickupLatLng != null) {
      c.addMarker('pickup', _pickupLatLng!.longitude, _pickupLatLng!.latitude);
    }
    if (_dropoffLatLng != null) {
      c.addMarker(
          'dropoff', _dropoffLatLng!.longitude, _dropoffLatLng!.latitude);
    }
    if (routePoints != null && routePoints.length >= 2) {
      final pts =
          routePoints.map((p) => (lng: p.longitude, lat: p.latitude)).toList();
      c.setPolyline('route', pts, color: '#FFD700', width: 5);
      c.fitBounds(pts, durationMs: 800);
    } else {
      c.removePolyline('route');
      if (_pickupLatLng != null) {
        c.flyTo(
          lng: _pickupLatLng!.longitude,
          lat: _pickupLatLng!.latitude,
          zoom: 14.0,
          durationMs: 600,
        );
      }
    }
  }

  void _fitMap() {
    if (!_mapReady || _pickupLatLng == null || _dropoffLatLng == null) return;
    final minLat = _pickupLatLng!.latitude < _dropoffLatLng!.latitude ? _pickupLatLng!.latitude : _dropoffLatLng!.latitude;
    final maxLat = _pickupLatLng!.latitude > _dropoffLatLng!.latitude ? _pickupLatLng!.latitude : _dropoffLatLng!.latitude;
    final minLng = _pickupLatLng!.longitude < _dropoffLatLng!.longitude ? _pickupLatLng!.longitude : _dropoffLatLng!.longitude;
    final maxLng = _pickupLatLng!.longitude > _dropoffLatLng!.longitude ? _pickupLatLng!.longitude : _dropoffLatLng!.longitude;
    _mapCtrl?.cameraForCoordinatesPadding(
      [mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
       mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat))],
      mapbox.CameraOptions(bearing: _cinematicBearing, pitch: _cinematicPitch),
      mapbox.MbxEdgeInsets(top: 80, left: 60, bottom: 80, right: 60),
      null, null,
    ).then((cam) {
      _mapCtrl?.flyTo(cam, mapbox.MapAnimationOptions(duration: 800));
    });
  }

  // ── Booking ──────────────────────────────────────────────────────────

  Future<void> _book() async {
    if (_pickupLatLng == null || _dropoffLatLng == null) {
      _showErr(S.of(context).enterBothAddresses);
      return;
    }
    if (_pickupAddress.isEmpty || _dropoffAddress.isEmpty) {
      _showErr(S.of(context).enterBothAddresses);
      return;
    }
    if (!_linkedPaymentMethods.contains(_selectedPaymentMethod)) {
      _showErr(S.of(context).pleaseAddPaymentFirst);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(S.of(context).confirmRide, style: const TextStyle(color: Colors.white)),
        content: Text(S.of(context).confirmBeforeSubmit, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(S.of(context).cancelBtn, style: const TextStyle(color: Colors.white70)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: _gold),
            child: Text(S.of(context).confirm, style: const TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isBooking = true);

    // Pre-capture localized strings before async gaps
    final localRideScheduledTitle = S.of(context).rideScheduled;
    final localRideScheduledMsg = S.of(context).rideScheduledMsg(
      DateFormat('MMM d \'at\' h:mm a').format(widget.scheduledAt),
    );

    try {
      final riderId = await ApiService.getCurrentUserId();
      if (riderId == null) throw Exception('Not logged in');

      final fareStr = _rides[_selectedRide].price
          .replaceAll('\$', '')
          .replaceAll(',', '');
      final fare = double.tryParse(fareStr) ?? 0;
      final isAirport = _airportSelection != null;
      final notes = _airportSelection?.flightNumber != null
          ? 'Flight: ${_airportSelection!.flightNumber}'
          : null;

      final tripData = await ApiService.createTrip(
        riderId: riderId,
        pickupAddress: _pickupAddress,
        dropoffAddress: _dropoffAddress,
        pickupLat: _pickupLatLng!.latitude,
        pickupLng: _pickupLatLng!.longitude,
        dropoffLat: _dropoffLatLng!.latitude,
        dropoffLng: _dropoffLatLng!.longitude,
        fare: fare,
        vehicleType: _rides[_selectedRide].name,
        scheduledAt: widget.scheduledAt,
        isAirport: isAirport,
        airportCode: _airportSelection?.airport.code,
        terminal: _airportSelection?.terminal?.name,
        pickupZone: _airportSelection?.arrivalDoor ?? _airportSelection?.airline,
        notes: notes,
      );

      final tripId = tripData['id'] as int?;

      // Fire-and-forget: local notification (non-blocking)
      if (tripId != null) {
        NotificationService.scheduleRideReminder(
          tripId: tripId,
          rideTime: widget.scheduledAt,
          pickup: _pickupAddress,
          dropoff: _dropoffAddress,
        ).catchError((_) {});
      }

      // Fire-and-forget: Firestore mirror (non-blocking)
      UserSession.getUser().then((session) {
        final milesStr = _tripMiles.replaceAll(_milesCleanRe, '');
        final km = (double.tryParse(milesStr) ?? 0.0) * 1.60934;
        final durStr = _tripDuration.replaceAll(_durCleanRe, '');
        final durMin = int.tryParse(durStr) ?? 0;
        final name =
            '${session?['firstName'] ?? ''} ${session?['lastName'] ?? ''}'
                .trim();
        TripFirestoreService.submitRideRequest(
          passengerName: name.isEmpty ? 'Passenger' : name,
          passengerPhone: session?['phone'] ?? '',
          pickupAddress: _pickupAddress,
          dropoffAddress: _dropoffAddress,
          pickupLat: _pickupLatLng!.latitude,
          pickupLng: _pickupLatLng!.longitude,
          dropoffLat: _dropoffLatLng!.latitude,
          dropoffLng: _dropoffLatLng!.longitude,
          fare: fare,
          distanceKm: km,
          durationMin: durMin,
          vehicleType: _rides[_selectedRide].name,
          paymentMethod: _selectedPaymentMethod,
          scheduledAt: widget.scheduledAt,
          isAirportTrip: isAirport,
        ).catchError((_) => '');
      }).catchError((_) {});

      // Fire-and-forget: local notification record
      LocalDataService.addNotification(
        title: localRideScheduledTitle,
        message: localRideScheduledMsg,
        type: 'ride',
      ).catchError((_) {});

      if (!mounted) return;

      // Navigate to confirmation screen (auto-fades to home after 3.5s)
      final fareVal = fare;
      final vehicleName = _rides[_selectedRide].name;
      Navigator.of(context).pushAndRemoveUntil(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => RideBookingConfirmedScreen(
            scheduledAt: widget.scheduledAt,
            pickupAddress: _pickupAddress,
            dropoffAddress: _dropoffAddress,
            vehicleType: vehicleName,
            fare: fareVal,
            pickupLat: _pickupLatLng?.latitude,
            pickupLng: _pickupLatLng?.longitude,
            dropoffLat: _dropoffLatLng?.latitude,
            dropoffLng: _dropoffLatLng?.longitude,
          ),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 500),
        ),
        (_) => false,
      );
    } catch (e) {
      if (mounted) _showErr(S.of(context).failedToBook('$e'));
    } finally {
      if (mounted) setState(() => _isBooking = false);
    }
  }

  void _showErr(String msg) {
    AppToast.error(context, msg);
  }

  // ── Payment ──────────────────────────────────────────────────────────

  void _showPaymentSelector() {
    final creditLabel = (_savedCardBrand != null && _savedCardLast4 != null)
        ? '${_savedCardBrand![0].toUpperCase()}${_savedCardBrand!.substring(1)} •••• $_savedCardLast4'
        : S.of(context).creditOrDebitCard;
    final methods = [
      if (AppPlatform.isIOS) ('apple_pay', 'Apple Pay', true),
      if (AppPlatform.isAndroid) ('google_pay', 'Google Pay', true),
      ('credit_card', creditLabel, true),
      ('paypal', 'PayPal', false), // Coming Soon
    ];
    final c = AppColors.of(context);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
        decoration: BoxDecoration(
          color: c.mapPanel,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4.5,
                decoration: BoxDecoration(
                  color: c.iconMuted,
                  borderRadius: BorderRadius.circular(40),
                ),
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  S.of(context).paymentMethodLabel,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ...methods.map((m) {
                final (id, label, enabled) = m;
                final selected = id == _selectedPaymentMethod;
                final linked = _linkedPaymentMethods.contains(id);
                return GestureDetector(
                  onTap: enabled
                      ? () {
                          Navigator.pop(ctx);
                          setState(() => _selectedPaymentMethod = id);
                          if (!linked) {
                            if (!mounted) return;
                            Navigator.push(
                              context,
                              slideFromRightRoute(const PaymentAccountsScreen()),
                            ).then((_) => _loadPayments());
                          }
                        }
                      : null,
                  child: Opacity(
                    opacity: enabled ? 1.0 : 0.45,
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
                          if (id == 'apple_pay' || id == 'google_pay')
                            Expanded(child: _nativePayLogoWide(id))
                          else ...[
                            _payLogo(id, 36),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    label,
                                    style: TextStyle(
                                      color: c.textPrimary,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    !enabled
                                        ? 'Coming Soon'
                                        : linked
                                            ? S.of(context).readyLabel
                                            : S.of(context).tapToSetUp,
                                    style: TextStyle(
                                      color: !enabled
                                          ? const Color(0xFFD4A843)
                                          : linked
                                              ? const Color(0xFF4CAF50)
                                              : c.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          if (selected && enabled)
                            const Icon(
                              Icons.check_circle_rounded,
                              color: _gold,
                              size: 22,
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _payLogo(String id, double size) {
    if (id == 'apple_pay') {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.grey.shade700, width: 0.5),
        ),
        child: Center(
          child: Icon(Icons.apple, color: Colors.white, size: size * 0.55),
        ),
      );
    }
    if (id == 'google_pay') {
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
          child: Image.asset('assets/images/google_g.png', fit: BoxFit.contain, cacheWidth: 80),
        ),
      );
    }
    if (id == 'paypal') {
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
    }
    // credit card
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1D24),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(Icons.credit_card_rounded, color: _gold, size: 20),
    );
  }

  String get _payLabel {
    if (_selectedPaymentMethod == 'apple_pay') return 'Apple Pay';
    if (_selectedPaymentMethod == 'google_pay') return 'Google Pay';
    if (_selectedPaymentMethod == 'paypal') return 'PayPal';
    if (_savedCardLast4 != null && _savedCardBrand != null) {
      final b = _savedCardBrand!;
      return '${b[0].toUpperCase()}${b.substring(1)} •••• $_savedCardLast4';
    }
    return S.of(context).creditCardLabel2;
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

  // ── Airport ──────────────────────────────────────────────────────────

  Future<void> _showAirportSheet() async {
    if (_airportSelection != null) {
      setState(() => _airportSelection = null);
      return;
    }
    final c = AppColors.of(context);
    final result = await showModalBottomSheet<AirportSelection>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => AirportTerminalSheet(isDark: c.isDark),
    );
    if (!mounted || result == null) return;
    setState(() {
      _airportSelection = result;
      _dropoffAddress = result.airport.name;
      _dropoffCtrl.text = result.airport.name;
    });
    final details = await _places.geocodeAddress(result.airport.name);
    if (!mounted) return;
    if (details != null) {
      setState(() => _dropoffLatLng = LatLng(details.lat, details.lng));
      _tryFetchRoute();
    }
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final schedLabel = DateFormat(
      "EEE, MMM d 'at' h:mm a",
    ).format(widget.scheduledAt);

    return Scaffold(
      backgroundColor: neuBase,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          Column(
            children: [
              // ── Header ──
              Container(
                color: neuBase,
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 8,
                  left: 16,
                  right: 16,
                  bottom: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () => Navigator.pop(context),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: neuBox(radius: 14, pressed: true),
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.arrow_back_ios_new_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                S.of(context).scheduleARide,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.3,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.calendar_today_rounded,
                                    color: _gold,
                                    size: 13,
                                  ),
                                  const SizedBox(width: 5),
                                  Flexible(
                                    child: Text(
                                      schedLabel,
                                      style: const TextStyle(
                                        color: _gold,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 14),

                    // ── Address inputs ──
                    Container(
                      decoration: neuBox(radius: 16),
                      child: Column(
                        children: [
                          _addressField(
                            ctrl: _pickupCtrl,
                            focus: _pickupFocus,
                            hint: S.of(context).pickupLocation,
                            icon: Icons.radio_button_checked,
                            iconColor: _gold,
                            onChanged: _onPickupChanged,
                            onClear: () {
                              _pickupCtrl.clear();
                              setState(() {
                                _pickupAddress = '';
                                _pickupLatLng = null;
                                _routeLoaded = false;
                              });
                            },
                          ),
                          Divider(
                            height: 1,
                            color: _gold.withValues(alpha: 0.2),
                          ),
                          _addressField(
                            ctrl: _dropoffCtrl,
                            focus: _dropoffFocus,
                            hint: S.of(context).whereTo,
                            icon: Icons.location_on_rounded,
                            iconColor: const Color(0xFFFF5252),
                            onChanged: _onDropoffChanged,
                            onClear: () {
                              _dropoffCtrl.clear();
                              setState(() {
                                _dropoffAddress = '';
                                _dropoffLatLng = null;
                                _routeLoaded = false;
                                _airportSelection = null;
                              });
                            },
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 8),

                    // Airport badge
                    GestureDetector(
                      onTap: _showAirportSheet,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: _airportSelection != null
                              ? const Color(0xFF4285F4).withValues(alpha: 0.15)
                              : Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(
                            color: _airportSelection != null
                                ? const Color(0xFF4285F4).withValues(alpha: 0.5)
                                : Colors.white24,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _airportSelection != null
                                  ? Icons.flight_rounded
                                  : Icons.flight_outlined,
                              color: _airportSelection != null
                                  ? const Color(0xFF4285F4)
                                  : Colors.white54,
                              size: 15,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _airportSelection != null
                                  ? S
                                        .of(context)
                                        .airportCodeTapToRemove(
                                          _airportSelection!.airport.code,
                                        )
                                  : S.of(context).airportRide,
                              style: TextStyle(
                                color: _airportSelection != null
                                    ? const Color(0xFF4285F4)
                                    : Colors.white54,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // ── Map ──
              Expanded(
                child: Stack(
                  children: [
                    if (!_mapMounted)
                      const Positioned.fill(
                        child: ColoredBox(color: Color(0xFF07080D)),
                      )
                    // The native MapWidget has no web implementation — GL JS
                    // takes over in the browser with the same route + pins.
                    else if (kIsWeb)
                      WebMapView(
                        key: const ValueKey('schedule_booking_map_web'),
                        initialLng: _mapCenter.longitude,
                        initialLat: _mapCenter.latitude,
                        initialZoom: 14.0,
                        styleUri: MapboxConfig.styleDark,
                        onControllerCreated: (c) {
                          _webMapCtrl = c;
                          c.applyNavyGoldTheme();
                          _refreshWebMap();
                        },
                      )
                    else
                    mapbox.MapWidget(
                      textureView: true,
                      styleUri: MapboxConfig.styleDark,
                      onMapLoadErrorListener: (err) => debugPrint('[ScheduleBooking] Load error: ${err.message} (type: ${err.type})'),
                      cameraOptions: mapbox.CameraOptions(
                        center: mapbox.Point(coordinates: mapbox.Position(_mapCenter.longitude, _mapCenter.latitude)),
                        zoom: 14.0,
                      ),
                      onMapCreated: (ctrl) async {
                        _mapCtrl = ctrl;
                        // Cache controller for reuse across rider screens
                        MapControllerCache.instance.cache(ctrl);
                        ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
                        ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
                        ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
                        ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));
                        _pointAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
                        try { await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-pitch-alignment', 'viewport'); } catch (_) {}
                        try { await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-allow-overlap', true); } catch (_) {}
                        try { await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-ignore-placement', true); } catch (_) {}
                        try { await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-anchor', 'bottom'); } catch (_) {}
                        _polylineAnnotMgr = await ctrl.annotations.createPolylineAnnotationManager(
                          below: 'road-label',
                        );
                        if (mounted) setState(() => _mapReady = true);
                        if (_pickupLatLng != null && _dropoffLatLng != null) {
                          _fitMap();
                        } else if (_pickupLatLng != null) {
                          // Center on GPS location when only pickup is set
                          _mapCtrl!.flyTo(
                            mapbox.CameraOptions(
                              center: mapbox.Point(coordinates: mapbox.Position(_pickupLatLng!.longitude, _pickupLatLng!.latitude)),
                              zoom: 14.0,
                            ),
                            mapbox.MapAnimationOptions(duration: 600),
                          );
                        }
                      },
                      onStyleLoadedListener: (_) async {
                        if (_mapCtrl != null) await MapTheme.applyNavyGold(_mapCtrl!);
                      },
                    ),
                    if (_isLoadingRoute)
                      const Center(
                        child: CircularProgressIndicator(
                          color: _gold,
                          strokeWidth: 2.5,
                        ),
                      ),
                    if (!_routeLoaded && !_isLoadingRoute)
                      Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            S.of(context).enterAddressesToSeeRoute,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // ── Bottom panel ──
              Container(
                decoration: neuBox(radius: 24).copyWith(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                ),
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    14,
                    16,
                    MediaQuery.of(context).padding.bottom + 16,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4.5,
                          decoration: BoxDecoration(
                            color: c.iconMuted,
                            borderRadius: BorderRadius.circular(40),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),

                      if (_routeLoaded) ...[
                        Text(
                          '$_tripMiles · $_tripDuration',
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],

                      // Ride options
                      ..._rides.asMap().entries.map((e) {
                        final i = e.key;
                        final ride = e.value;
                        final selected = i == _selectedRide;
                        final accent = _rideAccentColor(ride.name);
                        final badgeInfo = _rideBadgeInfo(ride.name);

                        return GestureDetector(
                          onTap: () => setState(() => _selectedRide = i),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 250),
                            margin: const EdgeInsets.only(bottom: 10),
                            height: 130,
                            decoration: BoxDecoration(
                              color: selected ? const Color(0xFF1A1F2E) : const Color(0xFF111318),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: selected ? accent.withValues(alpha: 0.6) : Colors.white.withValues(alpha: 0.07),
                                width: selected ? 1.5 : 1.0,
                              ),
                              boxShadow: selected
                                  ? [BoxShadow(color: accent.withValues(alpha: 0.15), blurRadius: 16, spreadRadius: 1)]
                                  : null,
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Row(
                                children: [
                                  // LEFT — Info
                                  Expanded(
                                    flex: 5,
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          // Badge
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: badgeInfo.$3,
                                              borderRadius: BorderRadius.circular(20),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(badgeInfo.$2, color: badgeInfo.$4, size: 10),
                                                const SizedBox(width: 3),
                                                Text(badgeInfo.$1, style: TextStyle(color: badgeInfo.$4, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                                              ],
                                            ),
                                          ),
                                          // Description + features
                                          Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                _rideDescription(ride.name),
                                                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700, height: 1.25),
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                _rideFeatures(ride.name),
                                                style: TextStyle(color: accent.withValues(alpha: 0.75), fontSize: 10, fontWeight: FontWeight.w500),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  // RIGHT — Car + road
                                  Expanded(
                                    flex: 4,
                                    child: Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        Positioned.fill(
                                          child: CustomPaint(
                                            painter: _RoadPerspectivePainter(color: accent, isSelected: selected),
                                          ),
                                        ),
                                        Positioned(
                                          bottom: 10,
                                          left: -6,
                                          right: 4,
                                          child: Transform(
                                            alignment: Alignment.center,
                                            transform: Matrix4.identity()..setEntry(3, 2, 0.001)..rotateY(-0.15),
                                            child: Image.asset(
                                              _rideCarAsset(ride.name),
                                              height: 65,
                                              fit: BoxFit.contain,
                                              cacheWidth: 200,
                                              errorBuilder: (_, __, ___) => const Icon(Icons.directions_car_rounded, color: _gold, size: 36),
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          top: 10,
                                          right: 10,
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.end,
                                            children: [
                                              Text(ride.price, style: TextStyle(color: accent, fontSize: 14, fontWeight: FontWeight.w800)),
                                              Text('est. fare', style: const TextStyle(color: Colors.white38, fontSize: 9)),
                                            ],
                                          ),
                                        ),
                                        if (selected)
                                          Positioned(
                                            bottom: 10,
                                            right: 10,
                                            child: Container(
                                              width: 20,
                                              height: 20,
                                              decoration: BoxDecoration(shape: BoxShape.circle, color: accent),
                                              child: const Icon(Icons.check_rounded, color: Colors.black, size: 12),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),

                      const SizedBox(height: 4),

                      // Payment method selector
                      GestureDetector(
                        onTap: _showPaymentSelector,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: neuBox(radius: 16),
                          child: Row(
                            children: [
                              if (_selectedPaymentMethod == 'apple_pay' || _selectedPaymentMethod == 'google_pay')
                                Expanded(child: _nativePayLogoWide(_selectedPaymentMethod))
                              else ...[    
                                _payLogo(_selectedPaymentMethod, 34),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _payLabel,
                                        style: TextStyle(
                                          color: c.textPrimary,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        _linkedPaymentMethods.contains(
                                              _selectedPaymentMethod,
                                            )
                                            ? S.of(context).tapToChange
                                            : S.of(context).notAddedTapToSetUp,
                                        style: TextStyle(
                                          color:
                                              _linkedPaymentMethods.contains(
                                                _selectedPaymentMethod,
                                              )
                                              ? c.textSecondary
                                              : Colors.white,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              const SizedBox(width: 8),
                              Icon(
                                Icons.chevron_right_rounded,
                                color: c.textSecondary,
                                size: 22,
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Book button — gold CTA with soft gold shadow
                      SizedBox(
                        width: double.infinity,
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: _gold.withValues(alpha: 0.3),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
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
                          onPressed: _isBooking ? null : _book,
                          child: _isBooking
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.black,
                                    strokeWidth: 2.5,
                                  ),
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(
                                      Icons.calendar_month_rounded,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 10),
                                    Flexible(
                                      child: Text(
                                        '${S.of(context).bookScheduledRide} · ${_rides[_selectedRide].price}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: -0.2,
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
              ),
            ],
          ),

          // Suggestions overlay
          if (_showSuggestions && _suggestions.isNotEmpty)
            Positioned(
              top: MediaQuery.of(context).padding.top + 110,
              left: 16,
              right: 16,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 280),
                  decoration: BoxDecoration(
                    color: c.mapPanel,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: c.border),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: _suggestions.length,
                      separatorBuilder: (_, __) =>
                          Divider(height: 1, color: c.border),
                      itemBuilder: (_, i) {
                        final s = _suggestions[i];
                        return InkWell(
                          onTap: () => _onSelectSuggestion(s),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  s.icon,
                                  color: const Color(0xFFD4AF37),
                                  size: 18,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    s.description,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: c.textPrimary,
                                      fontSize: 14,
                                    ),
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
              ),
            ),
        ],
      ),
    );
  }

  Widget _addressField({
    required TextEditingController ctrl,
    required FocusNode focus,
    required String hint,
    required IconData icon,
    required Color iconColor,
    required ValueChanged<String> onChanged,
    required VoidCallback onClear,
  }) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: ctrl,
              focusNode: focus,
              style: TextStyle(color: c.textPrimary, fontSize: 15),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(color: c.textSecondary, fontSize: 15),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              onChanged: onChanged,
              onTap: () => setState(() => _showSuggestions = true),
            ),
          ),
          if (ctrl.text.isNotEmpty)
            GestureDetector(
              onTap: onClear,
              child: Icon(
                Icons.close_rounded,
                color: c.textSecondary,
                size: 18,
              ),
            ),
        ],
      ),
    );
  }
}

class _RideOption {
  final String name;
  final String vehicle;
  final String price;
  final String eta;
  final bool promoted;

  const _RideOption({
    required this.name,
    required this.vehicle,
    required this.price,
    required this.eta,
    this.promoted = false,
  });
}

/// 3D perspective road painted under ride card car images.
class _RoadPerspectivePainter extends CustomPainter {
  final Color color;
  final bool isSelected;

  _RoadPerspectivePainter({required this.color, required this.isSelected});

  @override
  void paint(Canvas canvas, Size size) {
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

    final edgePaint = Paint()
      ..color = color.withValues(alpha: isSelected ? 0.3 : 0.1)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(size.width * 0.1, size.height * 0.3), Offset(0, size.height), edgePaint);
    canvas.drawLine(Offset(size.width * 0.9, size.height * 0.3), Offset(size.width, size.height), edgePaint);

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
