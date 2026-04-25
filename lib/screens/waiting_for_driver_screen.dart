import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../config/api_keys.dart';
import '../config/map_theme.dart';
import '../config/mapbox_config.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../models/lat_lng.dart';
import '../services/directions_service.dart';
import '../widgets/map/circular_pin_renderer.dart';

/// Pantalla "Casi listo..." - Se muestra después del pago confirmado
/// Muestra el mapa con la ruta, labels DESTINO/RECOGIDA, y detalles del viaje
class WaitingForDriverScreen extends StatefulWidget {
  final LatLng pickupLatLng;
  final LatLng dropoffLatLng;
  final String pickupAddress;
  final String dropoffAddress;
  final List<LatLng>? routePoints;
  final String? driverName;
  final String? driverPhotoUrl;
  final String? vehicleInfo;
  final VoidCallback? onCancel;
  final ValueNotifier<bool>? driverFound;

  const WaitingForDriverScreen({
    super.key,
    required this.pickupLatLng,
    required this.dropoffLatLng,
    required this.pickupAddress,
    required this.dropoffAddress,
    this.routePoints,
    this.driverName,
    this.driverPhotoUrl,
    this.vehicleInfo,
    this.onCancel,
    this.driverFound,
  });

  @override
  State<WaitingForDriverScreen> createState() => _WaitingForDriverScreenState();
}

class _WaitingForDriverScreenState extends State<WaitingForDriverScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _bg = Color(0xFF0A0A0A);
  static const _cardBg = Color(0xFF1A1A1A);

  mapbox.MapboxMap? _mapCtrl;
  mapbox.PolylineAnnotationManager? _polyMgr;
  mapbox.PointAnnotationManager? _pointMgr;
  mapbox.PolylineAnnotation? _routeAnnot;
  
  List<LatLng> _routePoints = [];
  bool _routeFetching = false;
  
  // Animations
  late final AnimationController _slideCtrl;
  late final Animation<Offset> _slideAnim;
  late final Animation<double> _slideFadeAnim;
  
  Ticker? _routeDrawTicker;
  VoidCallback? _driverFoundCb;

  @override
  void initState() {
    super.initState();
    
    // Listen for driver found event
    if (widget.driverFound != null) {
      _driverFoundCb = () {
        if (widget.driverFound!.value && mounted) {
          Navigator.of(context).pop();
        }
      };
      widget.driverFound!.addListener(_driverFoundCb!);
      // Check if already found
      if (widget.driverFound!.value) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop();
        });
      }
    }
    
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic));
    _slideFadeAnim = CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic);
    
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) _slideCtrl.forward();
    });
    
    _prefetchRoute();
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    if (_driverFoundCb != null) {
      widget.driverFound?.removeListener(_driverFoundCb!);
    }
    super.dispose();
  }

  Future<void> _prefetchRoute() async {
    if (widget.routePoints != null && widget.routePoints!.length >= 2) {
      _routePoints = List.of(widget.routePoints!);
    } else {
      setState(() => _routeFetching = true);
      _routePoints = await _fetchRoutePoints(widget.pickupLatLng, widget.dropoffLatLng);
      if (mounted) setState(() => _routeFetching = false);
    }
  }

  Future<List<LatLng>> _fetchRoutePoints(LatLng o, LatLng d) async {
    try {
      final result = await DirectionsService(ApiKeys.webServices).getRoute(
        origin: o,
        destination: d,
      );
      if (result != null && result.points.isNotEmpty) return result.points;
    } catch (_) {}
    
    // Fallback: línea recta
    return List.generate(21, (i) {
      final t = i / 20;
      return LatLng(
        o.latitude + (d.latitude - o.latitude) * t,
        o.longitude + (d.longitude - o.longitude) * t,
      );
    });
  }

  Future<void> _onMapReady(mapbox.MapboxMap ctrl) async {
    _mapCtrl = ctrl;
    await MapTheme.applyNavyGold(ctrl);
    ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
    ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
    ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
    ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));

    _polyMgr = await ctrl.annotations.createPolylineAnnotationManager();
    _pointMgr = await ctrl.annotations.createPointAnnotationManager();
    
    // Add pins
    _addSmartPins();
    
    // Draw route
    while (_routeFetching && mounted) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    if (!mounted) return;
    if (_routePoints.length >= 2) {
      await _animateRouteDraw();
    }
  }

  Future<void> _addSmartPins() async {
    final mgr = _pointMgr;
    if (mgr == null) return;
    
    // Pickup pin
    final pickupBytes = await renderCircularPinBytes(
      icon: CircularPinIcon.person, 
      isPickup: true, 
      radius: 32,
    );
    await mgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(
        coordinates: mapbox.Position(
          widget.pickupLatLng.longitude,
          widget.pickupLatLng.latitude,
        ),
      ),
      image: pickupBytes,
      iconSize: 0.5,
      iconAnchor: mapbox.IconAnchor.BOTTOM,
    ));
    
    // Dropoff pin
    final dropoffBytes = await renderCircularPinBytes(
      icon: CircularPinIcon.flag, 
      isPickup: false, 
      radius: 32,
    );
    if (!mounted) return;
    await mgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(
        coordinates: mapbox.Position(
          widget.dropoffLatLng.longitude,
          widget.dropoffLatLng.latitude,
        ),
      ),
      image: dropoffBytes,
      iconSize: 0.5,
      iconAnchor: mapbox.IconAnchor.BOTTOM,
    ));
  }

  Future<void> _animateRouteDraw() async {
    final polyMgr = _polyMgr;
    if (polyMgr == null || _routePoints.length < 2) return;

    final initCoords = _routePoints.sublist(0, 2)
        .map((p) => mapbox.Position(p.longitude, p.latitude))
        .toList();
    _routeAnnot = await polyMgr.create(mapbox.PolylineAnnotationOptions(
      geometry: mapbox.LineString(coordinates: initCoords),
      lineColor: const Color(0xFFFFD700).toARGB32(),
      lineWidth: 5.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));
    if (!mounted || _routeAnnot == null) return;

    final cumDist = <double>[0.0];
    for (int i = 1; i < _routePoints.length; i++) {
      final dx = _routePoints[i].longitude - _routePoints[i - 1].longitude;
      final dy = _routePoints[i].latitude - _routePoints[i - 1].latitude;
      cumDist.add(cumDist.last + math.sqrt(dx * dx + dy * dy));
    }
    final totalDist = cumDist.last;
    if (totalDist <= 0) return;

    final totalMs = 2000;
    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    bool updating = false;

    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = createTicker((_) {
      if (!mounted) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      if (updating) return;
      
      final elapsed = stopwatch.elapsedMilliseconds;
      final progress = (elapsed / totalMs).clamp(0.0, 1.0);
      final targetDist = progress * totalDist;

      int seg = 0;
      for (int i = 1; i < cumDist.length; i++) {
        if (cumDist[i] >= targetDist) { seg = i - 1; break; }
        if (i == cumDist.length - 1) seg = i - 1;
      }

      final segLen = cumDist[seg + 1] - cumDist[seg];
      final frac = segLen > 0 ? (targetDist - cumDist[seg]) / segLen : 1.0;

      final coords = <mapbox.Position>[];
      for (int i = 0; i <= seg; i++) {
        coords.add(mapbox.Position(_routePoints[i].longitude, _routePoints[i].latitude));
      }
      final tipLat = _routePoints[seg].latitude + frac * (_routePoints[seg + 1].latitude - _routePoints[seg].latitude);
      final tipLng = _routePoints[seg].longitude + frac * (_routePoints[seg + 1].longitude - _routePoints[seg].longitude);
      coords.add(mapbox.Position(tipLng, tipLat));

      _routeAnnot!.geometry = mapbox.LineString(coordinates: coords);
      updating = true;
      polyMgr.update(_routeAnnot!).then((_) => updating = false).catchError((_) => updating = false);

      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        final fullCoords = _routePoints.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        _routeAnnot?.geometry = mapbox.LineString(coordinates: fullCoords);
        if (_routeAnnot != null) polyMgr.update(_routeAnnot!);
        if (!completer.isCompleted) completer.complete();
      }
    });
    _routeDrawTicker!.start();
    return completer.future;
  }

  void _showCancelDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a2e),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFc8a951), width: 1),
        ),
        title: Text(
          S.of(context).cancelRideQuestion,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
          textAlign: TextAlign.center,
        ),
        content: Text(
          S.of(context).cancelRideMsg,
          style: const TextStyle(color: Colors.grey, fontSize: 14),
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              S.of(context).keepWaiting,
              style: const TextStyle(color: Color(0xFFc8a951)),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFc8a951),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              widget.onCancel?.call();
              Navigator.of(context).pop();
            },
            child: Text(
              S.of(context).yesCancelBtn,
              style: const TextStyle(color: Colors.black),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final loc = S.of(context);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _bg,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Map background
            Positioned.fill(
              child: mapbox.MapWidget(
                styleUri: MapboxConfig.styleDark,
                cameraOptions: mapbox.CameraOptions(
                  center: mapbox.Point(
                    coordinates: mapbox.Position(
                      (widget.pickupLatLng.longitude + widget.dropoffLatLng.longitude) / 2,
                      (widget.pickupLatLng.latitude + widget.dropoffLatLng.latitude) / 2,
                    ),
                  ),
                  zoom: 13.5,
                  pitch: 45.0,
                  bearing: _calculateBearing(),
                ),
                onMapCreated: _onMapReady,
              ),
            ),
            
            // Gradient overlay
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.3),
                      Colors.black.withValues(alpha: 0.5),
                      Colors.black.withValues(alpha: 0.8),
                    ],
                    stops: const [0.0, 0.4, 1.0],
                  ),
                ),
              ),
            ),
            
            // Labels flotantes DESTINO y RECOGIDA
            _buildFloatingLabels(),
            
            // Back button
            Positioned(
              top: MediaQuery.of(context).padding.top + 16,
              left: 16,
              child: GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                  ),
                  child: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 20),
                ),
              ),
            ),
            
            // Bottom sheet "Casi listo..."
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: SlideTransition(
                position: _slideAnim,
                child: FadeTransition(
                  opacity: _slideFadeAnim,
                  child: Container(
                    padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottomPad),
                    decoration: BoxDecoration(
                      color: _cardBg,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                      border: Border(
                        top: BorderSide(color: _gold.withValues(alpha: 0.3)),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Handle bar
                        Center(
                          child: Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        
                        // Icono y título
                        Row(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: _gold.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: _gold.withValues(alpha: 0.3)),
                              ),
                              child: const Icon(Icons.directions_car, color: _gold, size: 24),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    loc.almostReady, // "Casi listo..."
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${_shortAddress(widget.pickupAddress)} → ${_shortAddress(widget.dropoffAddress)}',
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.6),
                                      fontSize: 13,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        
                        const SizedBox(height: 20),
                        
                        // Progress bar dorado
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            backgroundColor: Colors.white.withValues(alpha: 0.1),
                            valueColor: const AlwaysStoppedAnimation<Color>(_gold),
                            minHeight: 3,
                          ),
                        ),
                        
                        const SizedBox(height: 20),
                        
                        // Botón Cancelar
                        Center(
                          child: TextButton(
                            onPressed: _showCancelDialog,
                            child: Text(
                              loc.cancel,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 15,
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
      ),
    );
  }

  Widget _buildFloatingLabels() {
    return Stack(
      children: [
        // Label DESTINO (dropoff)
        Positioned(
          top: MediaQuery.of(context).padding.top + 80,
          left: 16,
          child: _buildMapLabel(
            icon: Icons.location_on,
            title: 'DESTINO',
            address: widget.dropoffAddress,
            isPickup: false,
          ),
        ),
        
        // Label RECOGIDA (pickup)
        Positioned(
          bottom: 280,
          right: 16,
          child: _buildMapLabel(
            icon: Icons.person_pin,
            title: 'RECOGIDA',
            address: widget.pickupAddress,
            isPickup: true,
          ),
        ),
      ],
    );
  }

  Widget _buildMapLabel({
    required IconData icon,
    required String title,
    required String address,
    required bool isPickup,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xF50F1120),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _gold.withValues(alpha: 0.35),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: _gold.withValues(alpha: 0.15),
            blurRadius: 20,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFF5DC7A), Color(0xFFD4A800)],
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: Colors.black, size: 13),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    color: _gold,
                    fontSize: 8.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _shortAddress(address),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _shortAddress(String address) {
    if (address.length > 35) {
      return '${address.substring(0, 35)}...';
    }
    return address;
  }

  double _calculateBearing() {
    final dLng = (widget.dropoffLatLng.longitude - widget.pickupLatLng.longitude) * math.pi / 180;
    final lat1 = widget.pickupLatLng.latitude * math.pi / 180;
    final lat2 = widget.dropoffLatLng.latitude * math.pi / 180;
    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }
}

Route<dynamic> waitingForDriverRoute({
  required LatLng pickupLatLng,
  required LatLng dropoffLatLng,
  required String pickupAddress,
  required String dropoffAddress,
  List<LatLng>? routePoints,
  VoidCallback? onCancel,
  ValueNotifier<bool>? driverFound,
}) {
  return PageRouteBuilder(
    opaque: false,
    transitionDuration: const Duration(milliseconds: 500),
    pageBuilder: (_, __, ___) => WaitingForDriverScreen(
      pickupLatLng: pickupLatLng,
      dropoffLatLng: dropoffLatLng,
      pickupAddress: pickupAddress,
      dropoffAddress: dropoffAddress,
      routePoints: routePoints,
      onCancel: onCancel,
      driverFound: driverFound,
    ),
    transitionsBuilder: (_, anim, __, child) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: anim,
          curve: Curves.easeInOut,
        ),
        child: child,
      );
    },
  );
}
