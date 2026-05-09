import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../../config/mapbox_config.dart';
import '../../config/map_theme.dart';
import '../../models/lat_lng.dart';
import '../../services/driver_map_provider.dart';
import 'driver_online_screen.dart';

/// ═══════════════════════════════════════════════════════════════════
///  DriverMapShellScreen — Single persistent map for all driver flows
/// ═══════════════════════════════════════════════════════════════════
///
/// This screen hosts ONE MapWidget that lives for the entire driver
/// session. All driver UIs are rendered as overlays on top of the map.
///
/// Instead of creating/destroying a MapWidget on every screen transition,
/// this shell keeps the map alive and switches UI overlays via
/// [DriverShellController].
///
/// Usage:
///   Navigator.push(context, MaterialPageRoute(
///     builder: (_) => DriverMapShellScreen(
///       initialState: DriverShellState.online,
///       photoUrl: photoUrl,
///       initialPos: currentLatLng,
///     ),
///   ));

class DriverMapShellScreen extends StatefulWidget {
  const DriverMapShellScreen({
    super.key,
    this.initialState = DriverShellState.online,
    this.photoUrl,
    this.initialPos,
    this.initialHeading = 0,
  });

  final DriverShellState initialState;
  final String? photoUrl;
  final LatLng? initialPos;
  final double initialHeading;

  @override
  State<DriverMapShellScreen> createState() => _DriverMapShellScreenState();
}

class _DriverMapShellScreenState extends State<DriverMapShellScreen> {
  mapbox.MapboxMap? _map;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PointAnnotationManager? _pinAnnotMgr;
  mapbox.PolylineAnnotationManager? _polylineAnnotMgr;
  bool _mapReady = false;
  String? _mapErrorMessage;

  late final DriverShellController _shellController;

  @override
  void initState() {
    super.initState();
    _shellController = DriverShellController();
    _shellController.navigateTo(widget.initialState);
  }

  @override
  void dispose() {
    _shellController.dispose();
    // NOTE: We intentionally do NOT dispose the map controller here.
    // The native map is expensive to recreate. It will be disposed
    // when the app closes or when explicitly cleared.
    super.dispose();
  }

  Future<void> _onMapCreated(mapbox.MapboxMap ctrl) async {
    _map = ctrl;

    // Disable default UI
    await ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
    await ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
    await ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
    await ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));

    // Create annotation managers
    _polylineAnnotMgr = await ctrl.annotations.createPolylineAnnotationManager(
      below: 'road-label',
    );
    _pointAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
    _pinAnnotMgr = await ctrl.annotations.createPointAnnotationManager();

    // Apply layer properties
    try { await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-pitch-alignment', 'viewport'); } catch (_) {}
    try { await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-allow-overlap', true); } catch (_) {}
    try { await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-ignore-placement', true); } catch (_) {}
    try { await ctrl.style.setStyleLayerProperty(_pinAnnotMgr!.id, 'icon-pitch-alignment', 'viewport'); } catch (_) {}
    try { await ctrl.style.setStyleLayerProperty(_pinAnnotMgr!.id, 'icon-rotation-alignment', 'viewport'); } catch (_) {}
    try { await ctrl.style.setStyleLayerProperty(_pinAnnotMgr!.id, 'icon-allow-overlap', true); } catch (_) {}
    try { await ctrl.style.setStyleLayerProperty(_pinAnnotMgr!.id, 'icon-ignore-placement', true); } catch (_) {}
    try { await ctrl.style.setStyleLayerProperty(_pinAnnotMgr!.id, 'icon-anchor', 'bottom'); } catch (_) {}

    // Apply theme
    await MapTheme.applyNavyGold(ctrl);

    if (mounted) {
      setState(() => _mapReady = true);
    }
  }

  Widget _buildOverlay() {
    return ListenableBuilder(
      listenable: _shellController,
      builder: (context, _) {
        switch (_shellController.state) {
          case DriverShellState.online:
            return DriverOnlineScreen.shell(
              photoUrl: widget.photoUrl,
              initialPos: widget.initialPos,
              initialHeading: widget.initialHeading,
            );
          case DriverShellState.tripAccept:
            // TODO: Extract DriverTripAcceptOverlay
            return _PlaceholderOverlay(
              label: 'Trip Accept',
              onBack: () => _shellController.goOnline(),
            );
          case DriverShellState.tripAccepted:
            return _PlaceholderOverlay(
              label: 'Trip Accepted',
              onBack: () => _shellController.goOnline(),
            );
          case DriverShellState.scheduledRides:
            return _PlaceholderOverlay(
              label: 'Scheduled Rides',
              onBack: () => _shellController.goOnline(),
            );
          case DriverShellState.scheduledDetails:
            return _PlaceholderOverlay(
              label: 'Ride Details',
              onBack: () => _shellController.navigateTo(DriverShellState.scheduledRides),
            );
          case DriverShellState.rateRider:
            return _PlaceholderOverlay(
              label: 'Rate Rider',
              onBack: () => _shellController.goOnline(),
            );
          case DriverShellState.home:
            // Home is not rendered inside the shell — it's the screen before the shell
            return const SizedBox.shrink();
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return DriverMapProvider(
      mapController: _map,
      pointAnnotMgr: _pointAnnotMgr,
      polylineAnnotMgr: _polylineAnnotMgr,
      pinAnnotMgr: _pinAnnotMgr,
      child: Scaffold(
        body: Stack(
          children: [
            // Persistent map (bottom layer)
            mapbox.MapWidget(
              key: const ValueKey('driver-shell-map'),
              styleUri: MapboxConfig.styleDark,
              cameraOptions: mapbox.CameraOptions(
                center: mapbox.Point(
                  coordinates: mapbox.Position(-73.9712, 40.7831), // NYC default
                ),
                zoom: 14.0,
              ),
              textureView: true,
              onMapCreated: _onMapCreated,
              onMapLoadErrorListener: (err) {
                debugPrint('[DriverShell] Map load error: ${err.message}');
                if (mounted) setState(() => _mapErrorMessage = err.message);
              },
            ),

            // Loading indicator while map initializes
            if (!_mapReady)
              Container(
                color: Colors.black,
                child: const Center(
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation(Color(0xFFE8C547)),
                  ),
                ),
              ),

            // Error overlay
            if (_mapErrorMessage != null)
              Container(
                color: Colors.black87,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.map_outlined, color: Colors.white38, size: 48),
                      const SizedBox(height: 16),
                      const Text(
                        'Map unavailable',
                        style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _mapErrorMessage!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),

            // Current overlay (top layer)
            if (_mapReady) _buildOverlay(),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Placeholder Overlay — Used for states not yet migrated
// ═══════════════════════════════════════════════════════════════════

class _PlaceholderOverlay extends StatelessWidget {
  final String label;
  final VoidCallback onBack;

  const _PlaceholderOverlay({required this.label, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: onBack,
            ),
            title: Text(label, style: const TextStyle(color: Colors.white)),
          ),
          const Expanded(
            child: Center(
              child: Text(
                'Overlay not yet migrated',
                style: TextStyle(color: Colors.white54),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
