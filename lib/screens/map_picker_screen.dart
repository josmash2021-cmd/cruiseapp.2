import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../config/api_keys.dart';
import '../config/app_theme.dart';
import '../config/map_theme.dart';
import '../config/mapbox_config.dart';
import '../l10n/app_localizations.dart';
import '../models/lat_lng.dart';
import '../services/places_service.dart';
import '../widgets/map/circular_pin_renderer.dart';

/// Full-screen map picker. User drags the map under a fixed center pin.
/// Returns a Map with 'address' (String), 'lat' (double), 'lng' (double).
class MapPickerScreen extends StatefulWidget {
  final double? initialLat;
  final double? initialLng;
  /// When true the pin shows a person icon and button says "Confirm Pickup".
  /// When false (default) pin shows a location icon and button says "Confirm Dropoff".
  final bool isPickup;
  const MapPickerScreen({super.key, this.initialLat, this.initialLng, this.isPickup = false});

  @override
  State<MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<MapPickerScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  final _places = PlacesService(ApiKeys.webServices);

  mapbox.MapboxMap? _mapCtrl;
  String _address = '';
  bool _addressIsPlaceholder = true;
  bool _loading = false;
  bool _geocodeFailed = false;
  LatLng _center = const LatLng(40.7128, -74.0060);
  Timer? _debounce;
  int _geocodeGen = 0; // generation counter to cancel stale requests
  late final AnimationController _settleCtrl;
  late final Animation<double> _settleAnim;

  // Confirm anchor animation
  AnimationController? _anchorCtrl;
  Animation<double>? _anchorAnim;
  bool _confirming = false;
  Ticker? _rippleTicker;
  double _rippleElapsed = 0.0;
  static const _rippleDurationMs = 1200.0;
  static const _waveCount = 3; // number of staggered waves

  @override
  void initState() {
    super.initState();
    _settleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _settleAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.05), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.05, end: 1.0), weight: 50),
    ]).animate(CurvedAnimation(parent: _settleCtrl, curve: Curves.easeOut));
    if (widget.initialLat != null && widget.initialLng != null) {
      _center = LatLng(widget.initialLat!, widget.initialLng!);
    } else {
      _resolveGpsCenter();
    }
  }

  /// When no initial coordinates are provided, fly map to the user's GPS location.
  Future<void> _resolveGpsCenter() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 5));
      if (!mounted) return;
      _center = LatLng(pos.latitude, pos.longitude);
      final map = _mapCtrl;
      if (map != null) {
        await map.flyTo(
          mapbox.CameraOptions(
            center: mapbox.Point(
              coordinates: mapbox.Position(pos.longitude, pos.latitude),
            ),
            zoom: 15.0,
          ),
          mapbox.MapAnimationOptions(duration: 800),
        );
      }
    } catch (_) {
      // GPS unavailable — keep default center
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _settleCtrl.dispose();
    _anchorCtrl?.dispose();
    _rippleTicker?.dispose();
    super.dispose();
  }

  void _scheduleGeocode() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _onCameraIdle);
  }

  Future<void> _onCameraIdle() async {
    _debounce?.cancel();
    if (!mounted) return;
    final gen = ++_geocodeGen;
    final snap = LatLng(_center.latitude, _center.longitude);
    if (_addressIsPlaceholder || _geocodeFailed) {
      setState(() {
        _loading = true;
        _geocodeFailed = false;
      });
    }
    String? addr;
    for (int attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted || gen != _geocodeGen) return;
      try {
        addr = await _places.reverseGeocode(
          lat: snap.latitude,
          lng: snap.longitude,
        );
        if (addr != null && addr.isNotEmpty) break;
      } catch (_) {}
    }
    if (!mounted || gen != _geocodeGen) return;
    setState(() {
      if (addr != null && addr.isNotEmpty) {
        _address = addr;
        _addressIsPlaceholder = false;
        _geocodeFailed = false;
      } else {
        _addressIsPlaceholder = true;
        _geocodeFailed = true;
      }
      _loading = false;
    });
  }

  void _onMapIdle(mapbox.MapIdleEventData event) {
    // Settle bounce on pin
    _settleCtrl.forward(from: 0);
    // Mapbox fires onMapIdle — schedule geocode
    _scheduleGeocode();
  }

  void _onCameraChanged(mapbox.CameraChangedEventData event) {
    // Update center on every camera change
    final map = _mapCtrl;
    if (map == null) return;
    map.getCameraState().then((state) {
      final coords = state.center.coordinates;
      _center = LatLng(coords.lat.toDouble(), coords.lng.toDouble());
    });
  }

  void _confirm() {
    if (_addressIsPlaceholder || _address.isEmpty || _confirming) {
      return;
    }
    setState(() => _confirming = true);

    // 1. Pin anchor drop animation (bounce spring)
    _anchorCtrl?.dispose();
    _anchorCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _anchorAnim = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: -18.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 25,
      ),
      TweenSequenceItem(
        tween: Tween(begin: -18.0, end: 4.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 40,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 4.0, end: -2.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 20,
      ),
      TweenSequenceItem(
        tween: Tween(begin: -2.0, end: 0.0)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 15,
      ),
    ]).animate(_anchorCtrl!);
    _anchorCtrl!.addListener(() => setState(() {}));
    _anchorCtrl!.forward(from: 0);

    // 2. Map-native ripple: add GeoJSON source + circle layers, animate with Ticker
    Future.delayed(const Duration(milliseconds: 260), () {
      if (!mounted) return;
      _startMapRipple();
    });

    // 3. Pop result after full animation
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (!mounted) return;
      Navigator.of(context).pop({
        'address': _address,
        'lat': _center.latitude,
        'lng': _center.longitude,
      });
    });
  }

  /// Meters-per-pixel at a given latitude and zoom level.
  double _metersPerPixel(double lat, double zoom) {
    return 156543.03392 *
        (1.0 / (1 << zoom.floor())) *
        (1.0 / (1.0 + (lat.abs() * 3.14159265 / 180.0).clamp(0.0, 1.2)));
  }

  Future<void> _startMapRipple() async {
    final map = _mapCtrl;
    if (map == null) return;

    final lng = _center.longitude;
    final lat = _center.latitude;

    // Create a GeoJSON point source at the pin location
    final geojson = jsonEncode({
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [lng, lat],
          },
          'properties': {},
        }
      ],
    });

    try {
      await map.style.addSource(mapbox.GeoJsonSource(id: 'ripple-source', data: geojson));
    } catch (_) {
      // Source might already exist
    }

    // Add circle layers for each wave (staggered)
    for (int i = 0; i < _waveCount; i++) {
      final layerId = 'ripple-wave-$i';
      try {
        await map.style.addLayer(mapbox.CircleLayer(
          id: layerId,
          sourceId: 'ripple-source',
          circleRadius: 0.0,
          circleColor: 0xFFD4A843,
          circleOpacity: 0.0,
          circleStrokeWidth: 2.5,
          circleStrokeColor: 0xFFE8C547,
          circleStrokeOpacity: 0.0,
        ));
      } catch (_) {}
    }

    // Animate using Ticker for smooth 60fps
    _rippleElapsed = 0.0;
    _rippleTicker?.dispose();
    _rippleTicker = createTicker((elapsed) {
      _rippleElapsed = elapsed.inMilliseconds.toDouble();
      if (_rippleElapsed > _rippleDurationMs) {
        _rippleTicker?.stop();
        _cleanupMapRipple();
        return;
      }
      _updateRippleLayers();
    })..start();
  }

  void _updateRippleLayers() {
    final map = _mapCtrl;
    if (map == null) return;

    for (int i = 0; i < _waveCount; i++) {
      final layerId = 'ripple-wave-$i';
      // Stagger each wave by 150ms
      final waveOffset = i * 150.0;
      final waveTime = (_rippleElapsed - waveOffset).clamp(0.0, _rippleDurationMs - waveOffset);
      final progress = (waveTime / (_rippleDurationMs - waveOffset)).clamp(0.0, 1.0);

      if (progress <= 0) continue;

      // Ease out curve for natural deceleration
      final eased = 1.0 - (1.0 - progress) * (1.0 - progress);
      // Max radius grows with each wave (outer waves go further)
      final maxRadius = 80.0 + (i * 30.0);
      final radius = maxRadius * eased;
      // Opacity: peaks early then fades out
      final opacity = progress < 0.15
          ? (progress / 0.15) * 0.35
          : 0.35 * (1.0 - ((progress - 0.15) / 0.85));
      final fillOpacity = opacity * 0.25; // fill is more subtle
      final strokeOpacity = opacity;
      final strokeWidth = (3.0 * (1.0 - eased * 0.5)).clamp(0.5, 3.0);

      // Update layer properties
      map.style.setStyleLayerProperty(layerId, 'circle-radius', radius);
      map.style.setStyleLayerProperty(layerId, 'circle-opacity', fillOpacity);
      map.style.setStyleLayerProperty(layerId, 'circle-stroke-opacity', strokeOpacity);
      map.style.setStyleLayerProperty(layerId, 'circle-stroke-width', strokeWidth);
    }
  }

  Future<void> _cleanupMapRipple() async {
    final map = _mapCtrl;
    if (map == null) return;
    for (int i = 0; i < _waveCount; i++) {
      try { await map.style.removeStyleLayer('ripple-wave-$i'); } catch (_) {}
    }
    try { await map.style.removeStyleSource('ripple-source'); } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = S.of(context);

    return Scaffold(
      body: Stack(
        children: [
          // Map — Mapbox on both iOS and Android
          RepaintBoundary(
            child: mapbox.MapWidget(
            styleUri: MapboxConfig.styleDark,
            cameraOptions: mapbox.CameraOptions(
              center: mapbox.Point(coordinates: mapbox.Position(_center.longitude, _center.latitude)),
              zoom: 15.0,
            ),
            onMapCreated: (ctrl) async {
              _mapCtrl = ctrl;
              ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
              ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
              ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
              ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));
              Future.delayed(
                const Duration(milliseconds: 800),
                _onCameraIdle,
              );
            },
            onStyleLoadedListener: (_) async {
              if (_mapCtrl != null) await MapTheme.applyNavyGold(_mapCtrl!);
            },
            onCameraChangeListener: _onCameraChanged,
            onMapIdleListener: _onMapIdle,
          ),
          ),

          // Center pin — tip sits at exact screen center (map coordinate)
          Center(
            child: Transform.translate(
              offset: Offset(0, -(46 * 1.0 / 2) + (_anchorAnim?.value ?? 0.0)),
              child: ScaleTransition(
                scale: _settleAnim,
                child: CircularMapPin(
                  size: 46,
                  icon: widget.isPickup ? CircularPinIcon.person : CircularPinIcon.flag,
                  isPickup: widget.isPickup,
                ),
              ),
            ),
          ),

          // Back button
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 16,
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c.bg.withValues(alpha: 0.9),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.arrow_back_rounded,
                  color: c.textPrimary,
                  size: 22,
                ),
              ),
            ),
          ),

          // Context hint pill
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: c.bg.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _gold.withValues(alpha: 0.25),
                  ),
                ),
                child: Text(
                  widget.isPickup ? s.setPickupOnMap : s.setDropoffOnMap,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),

          // Bottom card with address + confirm
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                color: c.panel,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
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
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Handle
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Address
                      Row(
                        children: [
                          Icon(
                            Icons.location_on_rounded,
                            color: _gold,
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _loading
                                ? Text(
                                    s.findingAddress,
                                    style: TextStyle(
                                      color: c.textTertiary,
                                      fontSize: 15,
                                    ),
                                  )
                                : GestureDetector(
                                    onTap: _geocodeFailed
                                        ? _onCameraIdle
                                        : null,
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            _addressIsPlaceholder
                                                ? s.pinnedLocation
                                                : _address,
                                            style: TextStyle(
                                              color: c.textPrimary,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w600,
                                            ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (_geocodeFailed)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              left: 8,
                                            ),
                                            child: Icon(
                                              Icons.refresh_rounded,
                                              color: _gold,
                                              size: 20,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Confirm button
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _gold,
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            elevation: 0,
                          ),
                          onPressed: (_loading || _confirming) ? null : _confirm,
                          child: Text(
                            widget.isPickup
                                ? s.confirmPickupLocation
                                : s.confirmDropoffLocation,
                            style: TextStyle(
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
        ],
      ),
    );
  }
}

