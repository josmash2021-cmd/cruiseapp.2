import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../config/map_theme.dart';
import '../config/mapbox_config.dart';
import '../map/unified_map_service.dart';
import '../models/lat_lng.dart';

/// ═══════════════════════════════════════════════════════════════════
///  RIDER MAP SHELL — Mapa único persistente para todo el flujo rider
/// ═══════════════════════════════════════════════════════════════════
///
/// Un único MapWidget que vive durante todo el flujo del pasajero.
/// Las pantallas (Home, Ride Request, Tracking, etc.) no crean mapas —
/// renderizan overlays encima de este shell y manipulan el mapa
/// a través de [UnifiedMapService].
///
/// Uso:
///   Navigator.of(context).push(MaterialPageRoute(
///     builder: (_) => RiderMapShellScreen(
///       initialOverlay: RiderOverlay.home,
///       pickupLatLng: userLocation,
///     ),
///   ));
class RiderMapShellScreen extends StatefulWidget {
  final RiderOverlay initialOverlay;
  final LatLng? pickupLatLng;
  final LatLng? dropoffLatLng;
  final Map<String, dynamic>? tripData;

  const RiderMapShellScreen({
    super.key,
    this.initialOverlay = RiderOverlay.home,
    this.pickupLatLng,
    this.dropoffLatLng,
    this.tripData,
  });

  @override
  State<RiderMapShellScreen> createState() => _RiderMapShellScreenState();
}

/// Overlays disponibles en el flujo rider.
enum RiderOverlay {
  home,           // Pantalla principal — botón "Where to"
  mapPicker,      // Mover pin de pickup
  rideRequest,    // Confirmar viaje — opciones de auto
  waiting,        // Buscando conductor
  tracking,       // Conductor en camino
  rating,         // Calificar viaje
}

class _RiderMapShellScreenState extends State<RiderMapShellScreen> {
  late RiderOverlay _currentOverlay;
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    _currentOverlay = widget.initialOverlay;
  }

  void _switchOverlay(RiderOverlay overlay, {Map<String, dynamic>? args}) {
    if (!mounted) return;
    setState(() => _currentOverlay = overlay);
  }

  Future<void> _onMapCreated(mapbox.MapboxMap controller) async {
    await UnifiedMapService.instance.initialize(controller);
    setState(() => _mapReady = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ── MAPA (capa base, siempre presente) ──
          mapbox.MapWidget(
            styleUri: MapboxConfig.styleDark,
            cameraOptions: mapbox.CameraOptions(
              center: widget.pickupLatLng != null
                  ? mapbox.Point(
                      coordinates: mapbox.Position(
                        widget.pickupLatLng!.longitude,
                        widget.pickupLatLng!.latitude,
                      ),
                    )
                  : null,
              zoom: 15,
            ),
            onMapCreated: _onMapCreated,
            onStyleLoadedListener: (_) {
              // Re-aplicar tema navy/gold cuando el estilo cambie
              final ctrl = UnifiedMapService.instance.controller;
              if (ctrl != null) MapTheme.applyNavyGold(ctrl);
            },
          ),

          // ── OVERLAY (UI encima del mapa) ──
          if (_mapReady) _buildOverlay(),

          // ── LOADING mientras el mapa inicializa ──
          if (!_mapReady)
            Container(
              color: const Color(0xFF08090C),
              child: const Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation(Color(0xFFE8C547)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildOverlay() {
    switch (_currentOverlay) {
      case RiderOverlay.home:
        return _HomeOverlay(
          onWhereTo: () => _switchOverlay(RiderOverlay.rideRequest),
          onMapPicker: () => _switchOverlay(RiderOverlay.mapPicker),
        );
      case RiderOverlay.mapPicker:
        return _MapPickerOverlay(
          onConfirm: (LatLng latLng) {
            // Actualizar pickup y volver a home
            _switchOverlay(RiderOverlay.home);
          },
          onCancel: () => _switchOverlay(RiderOverlay.home),
        );
      case RiderOverlay.rideRequest:
        return _RideRequestOverlay(
          pickupLatLng: widget.pickupLatLng,
          dropoffLatLng: widget.dropoffLatLng,
          onConfirm: () => _switchOverlay(RiderOverlay.waiting),
          onCancel: () => _switchOverlay(RiderOverlay.home),
        );
      case RiderOverlay.waiting:
        return _WaitingOverlay(
          onDriverFound: () => _switchOverlay(RiderOverlay.tracking),
          onCancel: () => _switchOverlay(RiderOverlay.home),
        );
      case RiderOverlay.tracking:
        return _TrackingOverlay(
          tripData: widget.tripData,
          onTripComplete: () => _switchOverlay(RiderOverlay.rating),
        );
      case RiderOverlay.rating:
        return _RatingOverlay(
          onDone: () {
            // Cerrar shell y volver a home limpio
            Navigator.of(context).pop();
          },
        );
    }
  }
}

// ═══════════════════════════════════════════════════════════════════
//  OVERLAY WIDGETS (stubs — se conectan a las pantallas reales)
// ═══════════════════════════════════════════════════════════════════

class _HomeOverlay extends StatelessWidget {
  final VoidCallback onWhereTo;
  final VoidCallback onMapPicker;

  const _HomeOverlay({required this.onWhereTo, required this.onMapPicker});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          const Spacer(),
          // Botón "Where to?"
          Padding(
            padding: const EdgeInsets.all(16),
            child: GestureDetector(
              onTap: onWhereTo,
              child: Container(
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.06),
                  ),
                ),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: const Text(
                  'Where to?',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
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

class _MapPickerOverlay extends StatelessWidget {
  final ValueChanged<LatLng> onConfirm;
  final VoidCallback onCancel;

  const _MapPickerOverlay({required this.onConfirm, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          // Header con botón cancelar
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                IconButton(
                  onPressed: onCancel,
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                ),
                const Spacer(),
                const Text(
                  'Set pickup location',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
                const Spacer(),
                const SizedBox(width: 48),
              ],
            ),
          ),
          const Spacer(),
          // Pin centrado (visual)
          const Icon(Icons.location_pin, color: Color(0xFFE8C547), size: 48),
          const SizedBox(height: 80),
          // Botón confirmar
          Padding(
            padding: const EdgeInsets.all(16),
            child: ElevatedButton(
              onPressed: () {
                // Obtener centro del mapa como pickup
                final ctrl = UnifiedMapService.instance.controller;
                if (ctrl != null) {
                  ctrl.getCameraState().then((state) {
                    final center = state.center;
                    if (center != null) {
                      onConfirm(LatLng(
                        center.coordinates.lat.toDouble(),
                        center.coordinates.lng.toDouble(),
                      ));
                    }
                  });
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE8C547),
                foregroundColor: Colors.black,
                minimumSize: const Size(double.infinity, 56),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Confirm Location', style: TextStyle(fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }
}

class _RideRequestOverlay extends StatelessWidget {
  final LatLng? pickupLatLng;
  final LatLng? dropoffLatLng;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const _RideRequestOverlay({
    this.pickupLatLng,
    this.dropoffLatLng,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                IconButton(
                  onPressed: onCancel,
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                ),
                const Expanded(
                  child: Text(
                    'Choose your ride',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
                const SizedBox(width: 48),
              ],
            ),
          ),
          const Spacer(),
          // Opciones de auto (stub)
          Container(
            height: 300,
            decoration: const BoxDecoration(
              color: Color(0xFF1C1C1E),
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Column(
              children: [
                const ListTile(
                  title: Text('Comfort', style: TextStyle(color: Colors.white)),
                  trailing: Text('\$12.50', style: TextStyle(color: Color(0xFFE8C547))),
                ),
                const ListTile(
                  title: Text('Premium', style: TextStyle(color: Colors.white)),
                  trailing: Text('\$18.00', style: TextStyle(color: Color(0xFFE8C547))),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: ElevatedButton(
                    onPressed: onConfirm,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE8C547),
                      foregroundColor: Colors.black,
                      minimumSize: const Size(double.infinity, 56),
                    ),
                    child: const Text('Confirm Ride'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WaitingOverlay extends StatelessWidget {
  final VoidCallback onDriverFound;
  final VoidCallback onCancel;

  const _WaitingOverlay({required this.onDriverFound, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    // Simular encontrar conductor después de 3 segundos
    Future.delayed(const Duration(seconds: 3), onDriverFound);

    return SafeArea(
      child: Column(
        children: [
          const Spacer(),
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                const CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation(Color(0xFFE8C547)),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Looking for your driver...',
                  style: TextStyle(color: Colors.white, fontSize: 18),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: onCancel,
                  child: const Text('Cancel', style: TextStyle(color: Colors.red)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackingOverlay extends StatelessWidget {
  final Map<String, dynamic>? tripData;
  final VoidCallback onTripComplete;

  const _TrackingOverlay({this.tripData, required this.onTripComplete});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          // Info del conductor
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0xFFE8C547),
                  child: Icon(Icons.person, color: Colors.black),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('John D.', style: TextStyle(color: Colors.white)),
                      Text('Toyota Camry • ABC123', style: TextStyle(color: Colors.white70)),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () {},
                  icon: const Icon(Icons.phone, color: Color(0xFFE8C547)),
                ),
              ],
            ),
          ),
          const Spacer(),
          // Botón para simular fin de viaje
          Padding(
            padding: const EdgeInsets.all(16),
            child: ElevatedButton(
              onPressed: onTripComplete,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE8C547),
                foregroundColor: Colors.black,
                minimumSize: const Size(double.infinity, 56),
              ),
              child: const Text('Simulate Arrival'),
            ),
          ),
        ],
      ),
    );
  }
}

class _RatingOverlay extends StatelessWidget {
  final VoidCallback onDone;

  const _RatingOverlay({required this.onDone});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        color: const Color(0xCC08090C),
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'How was your ride?',
                  style: TextStyle(color: Colors.white, fontSize: 20),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(5, (i) {
                    return IconButton(
                      onPressed: onDone,
                      icon: const Icon(Icons.star_border, color: Color(0xFFE8C547)),
                    );
                  }),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: onDone,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE8C547),
                    foregroundColor: Colors.black,
                  ),
                  child: const Text('Submit'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
