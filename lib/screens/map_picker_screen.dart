import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:apple_maps_flutter/apple_maps_flutter.dart' as amap;
import '../config/api_keys.dart';
import '../config/app_theme.dart';
import '../config/map_styles.dart';
import '../l10n/app_localizations.dart';
import '../services/places_service.dart';

/// Full-screen map picker. User drags the map under a fixed center pin.
/// Returns a Map with 'address' (String), 'lat' (double), 'lng' (double).
class MapPickerScreen extends StatefulWidget {
  final double? initialLat;
  final double? initialLng;
  const MapPickerScreen({super.key, this.initialLat, this.initialLng});

  @override
  State<MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<MapPickerScreen> {
  static const _gold = Color(0xFFE8C547);
  final _places = PlacesService(ApiKeys.webServices);

  GoogleMapController? _mapCtrl;
  amap.AppleMapController? _appleMapCtrl;
  String _address = '';
  bool _addressIsPlaceholder = true;
  bool _loading = false;
  bool _geocodeFailed = false;
  LatLng _center = const LatLng(40.7128, -74.0060);
  Timer? _debounce;
  int _geocodeGen = 0; // generation counter to cancel stale requests

  @override
  void initState() {
    super.initState();
    if (widget.initialLat != null && widget.initialLng != null) {
      _center = LatLng(widget.initialLat!, widget.initialLng!);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
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

  void _onCameraMove(CameraPosition pos) {
    _center = pos.target;
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
          // Map
          Platform.isIOS
              ? amap.AppleMap(
                  initialCameraPosition: amap.CameraPosition(
                    target: amap.LatLng(_center.latitude, _center.longitude),
                    zoom: 15,
                  ),
                  onMapCreated: (ctrl) {
                    _appleMapCtrl = ctrl;
                    Future.delayed(
                      const Duration(milliseconds: 1000),
                      _onCameraIdle,
                    );
                  },
                  onCameraMove: (pos) {
                    _center = LatLng(pos.target.latitude, pos.target.longitude);
                    _scheduleGeocode();
                  },
                  onCameraIdle: _scheduleGeocode,
                  myLocationEnabled: true,
                  myLocationButtonEnabled: false,
                  mapType: amap.MapType.standard,
                )
              : GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: _center,
                    zoom: 15,
                  ),
                  onMapCreated: (ctrl) {
                    _mapCtrl = ctrl;
                    Future.delayed(
                      const Duration(milliseconds: 800),
                      _onCameraIdle,
                    );
                  },
                  onCameraMove: _onCameraMove,
                  onCameraIdle: _scheduleGeocode,
                  myLocationEnabled: true,
                  myLocationButtonEnabled: false,
                  zoomControlsEnabled: false,
                  mapToolbarEnabled: false,
                  style: MapStyles.dark,
                ),

          // Center pin
          Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 36),
              child: Icon(
                Icons.location_on,
                size: 48,
                color: const Color(0xFFE8C547),
                shadows: [
                  Shadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 8,
                  ),
                ],
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
                            s.confirmLocation,
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
