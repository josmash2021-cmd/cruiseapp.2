import 'dart:async';
import 'package:flutter/material.dart';
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
    with SingleTickerProviderStateMixin {
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
    // Only show loading if we don't already have an address
    if (_addressIsPlaceholder || _geocodeFailed) {
      setState(() {
        _loading = true;
        _geocodeFailed = false;
      });
    }
    String? addr;
    for (int attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted || gen != _geocodeGen) return; // stale
      try {
        addr = await _places.reverseGeocode(
          lat: snap.latitude,
          lng: snap.longitude,
        );
        if (addr != null && addr.isNotEmpty) break;
      } catch (_) {}
    }
    if (!mounted || gen != _geocodeGen) return; // stale
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
    if (_addressIsPlaceholder || _address.isEmpty) {
      return;
    }
    Navigator.of(context).pop({
      'address': _address,
      'lat': _center.latitude,
      'lng': _center.longitude,
    });
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

          // Center pin — fixed while map moves underneath
          Center(
            child: Transform.translate(
              offset: const Offset(0, -36),
              child: ScaleTransition(
                scale: _settleAnim,
                child: CircularMapPin(
                  size: 56,
                  icon: widget.isPickup ? CircularPinIcon.person : CircularPinIcon.flag,
                  isPickup: widget.isPickup,
                ),
              ),
            ),
          ),

          // Shadow dot on map under pin tip
          Center(
            child: Transform.translate(
              offset: const Offset(0, 4),
              child: Container(
                width: 8,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black38,
                  borderRadius: BorderRadius.circular(4),
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
                          onPressed: _loading ? null : _confirm,
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
