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
import '../widgets/gold_particles_background.dart';
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
  static const _bg = Color(0xFF0A1128);

  // Shimmer animation for progress bar (web: vipTestBarShimmer)
  late final AnimationController _shimmerCtrl;

  mapbox.MapboxMap? _mapCtrl;
  mapbox.PolylineAnnotationManager? _polyMgr;
  mapbox.PointAnnotationManager? _pointMgr;
  mapbox.PolylineAnnotation? _routeAnnot;

  List<LatLng> _routePoints = [];
  bool _routeFetching = false;
  // 2026-04-27: track the on-screen coordinates of the pickup/dropoff
  // pins so the labels can sit beside the pin instead of being pinned
  // at hardcoded screen positions (top + 80 / bottom + 280) that
  // ignored the camera state. Updated every 250ms via the camera-sync
  // timer below so the labels follow the pin during the smooth zoom-out.
  Offset? _pickupScreenPos;
  Offset? _dropoffScreenPos;
  Timer? _cameraSyncTimer;
  
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
    
    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    // web: transform:translateY(40px) → ~0.18 of sheet height
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.18),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideCtrl, curve: const Cubic(0.2, 0.8, 0.2, 1)));
    _slideFadeAnim = CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOut);
    
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) _slideCtrl.forward();
    });
    
    _prefetchRoute();
  }

  @override
  void dispose() {
    _shimmerCtrl.dispose();
    _slideCtrl.dispose();
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _cameraSyncTimer?.cancel();
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

    // Smooth zoom-out so both pickup + dropoff land in view together.
    // Initial cameraOptions zoom is 13.5 which on long trips leaves
    // one pin off-screen — easeTo to a fitted bounds over 1.6s gives
    // a cinematic reveal of the full route.
    Future.delayed(const Duration(milliseconds: 400), () async {
      if (!mounted || _mapCtrl == null) return;
      try {
        final cam = await _mapCtrl!.cameraForCoordinatesPadding(
          [
            mapbox.Point(coordinates: mapbox.Position(
              widget.pickupLatLng.longitude,
              widget.pickupLatLng.latitude,
            )),
            mapbox.Point(coordinates: mapbox.Position(
              widget.dropoffLatLng.longitude,
              widget.dropoffLatLng.latitude,
            )),
          ],
          mapbox.CameraOptions(bearing: _calculateBearing(), pitch: 35.0),
          mapbox.MbxEdgeInsets(
            top: MediaQuery.of(context).padding.top + 120,
            bottom: 280,
            left: 60,
            right: 60,
          ),
          null, null,
        );
        if (!mounted || _mapCtrl == null) return;
        // Clamp zoom so we never zoom IN more than the initial view —
        // a short trip should stay at 13.5, long trips zoom OUT.
        final z = (cam.zoom ?? 13.5).clamp(9.0, 13.5);
        _mapCtrl!.easeTo(
          mapbox.CameraOptions(
            center: cam.center,
            zoom: z,
            bearing: cam.bearing,
            pitch: cam.pitch,
            padding: cam.padding,
          ),
          mapbox.MapAnimationOptions(duration: 1600),
        );
      } catch (e) {
        debugPrint('[WaitingForDriver] zoom-out failed: $e');
      }
    });

    // Start syncing pin screen positions so floating labels can follow
    // them as the camera moves (zoom-out cinematic). 250ms is fast
    // enough that the eye doesn't see the labels lag behind the pins.
    _cameraSyncTimer?.cancel();
    _cameraSyncTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _syncPinScreenPositions(),
    );
    unawaited(_syncPinScreenPositions());

    // Draw route
    while (_routeFetching && mounted) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    if (!mounted) return;
    if (_routePoints.length >= 2) {
      await _animateRouteDraw();
    }
  }

  /// Project the pickup + dropoff lat/lng to the current screen
  /// coordinates so the floating labels can sit beside them. Returns
  /// null for any pin that isn't currently inside the visible map area
  /// (the label hides when the pin is off-screen).
  Future<void> _syncPinScreenPositions() async {
    final mc = _mapCtrl;
    if (mc == null || !mounted) return;
    try {
      final mq = MediaQuery.of(context);
      final screenW = mq.size.width;
      final screenH = mq.size.height;

      final pickPx = await mc.pixelForCoordinate(mapbox.Point(
        coordinates: mapbox.Position(
          widget.pickupLatLng.longitude,
          widget.pickupLatLng.latitude,
        ),
      ));
      final dropPx = await mc.pixelForCoordinate(mapbox.Point(
        coordinates: mapbox.Position(
          widget.dropoffLatLng.longitude,
          widget.dropoffLatLng.latitude,
        ),
      ));
      if (!mounted) return;
      // Reserve top-bar (80px) + bottom sheet area (~280px) so a label
      // never paints over the chrome. Pin is "visible" only if its
      // pixel position is inside the map's clear area.
      const topReserve = 80.0;
      const bottomReserve = 280.0;
      bool inView(num x, num y) =>
          x >= 0 && x <= screenW && y >= topReserve && y <= screenH - bottomReserve;
      setState(() {
        _pickupScreenPos = inView(pickPx.x, pickPx.y)
            ? Offset(pickPx.x.toDouble(), pickPx.y.toDouble())
            : null;
        _dropoffScreenPos = inView(dropPx.x, dropPx.y)
            ? Offset(dropPx.x.toDouble(), dropPx.y.toDouble())
            : null;
      });
    } catch (_) {/* mapbox not ready yet */}
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
                textureView: true,
                styleUri: MapboxConfig.styleDark,
                onMapLoadErrorListener: (err) => debugPrint('[WaitingDriver] Load error: ${err.message} (type: ${err.type})'),
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
            
            // Gradient overlay — web: rgba(6,10,24,.58) + blur
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      const Color(0xFF060A18).withValues(alpha: 0.25),
                      const Color(0xFF060A18).withValues(alpha: 0.45),
                      const Color(0xFF060A18).withValues(alpha: 0.75),
                    ],
                    stops: const [0.0, 0.4, 1.0],
                  ),
                ),
              ),
            ),
            
            // Labels flotantes DESTINO y RECOGIDA
            _buildFloatingLabels(),
            
            
            // Bottom sheet — web: .vipRide__testConfirm__phase2 + .vipRide__testSheet
            Positioned(
              bottom: math.max(bottomPad, 14),
              left: 14,
              right: 14,
              child: SlideTransition(
                position: _slideAnim,
                child: FadeTransition(
                  opacity: _slideFadeAnim,
                  child: Container(
                    // web: padding:16px 18px clamp(18px,5vw,24px)
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 22),
                    decoration: BoxDecoration(
                      // web: linear-gradient(160deg,rgba(13,20,45,.98),rgba(8,14,32,.99))
                      gradient: const LinearGradient(
                        begin: Alignment(-0.3, -1),
                        end: Alignment(0.3, 1),
                        colors: [
                          Color(0xFA0D142D),
                          Color(0xFC080E20),
                        ],
                      ),
                      // web: border-radius:20px
                      borderRadius: BorderRadius.circular(20),
                      // web: box-shadow:0 8px 48px rgba(0,0,0,.65),0 0 0 1px rgba(255,255,255,.06)
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.65),
                          blurRadius: 48,
                          offset: const Offset(0, 8),
                        ),
                      ],
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.06),
                        width: 1,
                      ),
                    ),
                    // clipBehavior so the GoldParticlesBackground field
                    // can't bleed past the sheet's rounded corners.
                    // Matches the look used on SearchingDriverScreen —
                    // the only other place in the app that renders
                    // gold particles (per the 2026-04-27 visual spec).
                    clipBehavior: Clip.antiAlias,
                    child: GoldParticlesBackground(
                      particleCount: 18,
                      child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Handle — web: width:38px height:4px rgba(255,255,255,.13)
                        Container(
                          width: 38,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.13),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(height: 14),
                        
                        // Row: icon + info — web: .vipRide__testSheet__row gap:14px
                        Row(
                          children: [
                            // Icon — web: 48x48 circle, rgba(232,197,71,.1) bg,
                            // border 1.5px rgba(232,197,71,.35), pulse rings
                            _buildPulsingIcon(),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // web: font-size:clamp(17px,4.8vw,20px) font-weight:700
                                  Text(
                                    loc.almostReady,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700,
                                      height: 1.2,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  // web: font-size:clamp(11px,3vw,13px) color:rgba(255,255,255,.4)
                                  Text(
                                    '${_shortAddress(widget.pickupAddress)} → ${_shortAddress(widget.dropoffAddress)}',
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.4),
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
                        
                        const SizedBox(height: 16),
                        
                        // Progress bar — web: .vipRide__testBar--phase2 shimmer
                        _buildShimmerBar(),
                        
                        const SizedBox(height: 4),
                        
                        // Cancel — web: font-size:clamp(14px,3.8vw,16px) color:rgba(255,255,255,.45)
                        TextButton(
                          onPressed: _showCancelDialog,
                          child: Text(
                            loc.cancel,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                    ),  // close GoldParticlesBackground
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
    // 2026-04-27 FIX: labels now SIT NEXT TO THE PIN they describe
    // (pickup label beside pickup pin, dropoff label beside dropoff
    // pin). Previously they were pinned to fixed screen offsets
    // (top + 80 / bottom + 280) so when a pin moved off-viewport
    // its label still rendered at its fixed slot up top — looked
    // disconnected from the actual pin location.
    //
    // _pickupScreenPos / _dropoffScreenPos are projected lat/lng
    // every 250ms by _syncPinScreenPositions. Each is null when the
    // pin is OFF-SCREEN, in which case we hide its label entirely
    // (the user requested: "if dropoff isn't visible the label
    // shouldn't appear up top either").
    final mq = MediaQuery.of(context);
    final screenW = mq.size.width;

    // Geometry to keep labels clear of the pin and clamped on screen.
    const double pillEstimatedWidth = 230.0;
    const double pillHalfHeight = 26.0;
    const double pillHeight = pillHalfHeight * 2;
    const double pinHalfWidth = 16.0;
    const double sideGap = 14.0;
    final topSafe = mq.padding.top + 12;
    final bottomSafe = mq.size.height - 280; // bottom sheet area

    Widget? pickupLabel;
    final pp = _pickupScreenPos;
    if (pp != null) {
      // Default RIGHT side; flip LEFT if it'd overflow.
      double left = pp.dx + pinHalfWidth + sideGap;
      if (left + pillEstimatedWidth > screenW - 8) {
        left = pp.dx - pinHalfWidth - sideGap - pillEstimatedWidth;
      }
      left = left.clamp(8.0, screenW - pillEstimatedWidth - 8.0);
      double top = pp.dy - pillHalfHeight;
      top = top.clamp(topSafe, bottomSafe - pillHeight);
      pickupLabel = Positioned(
        left: left,
        top: top,
        child: _buildMapLabel(
          icon: Icons.person_pin,
          title: 'RECOGIDA',
          address: widget.pickupAddress,
          isPickup: true,
        ),
      );
    }

    Widget? dropoffLabel;
    final dp = _dropoffScreenPos;
    if (dp != null) {
      // Default LEFT side for dropoff; flip RIGHT if it'd overflow.
      double left = dp.dx - pinHalfWidth - sideGap - pillEstimatedWidth;
      if (left < 8) {
        left = dp.dx + pinHalfWidth + sideGap;
      }
      left = left.clamp(8.0, screenW - pillEstimatedWidth - 8.0);
      double top = dp.dy - pillHalfHeight;
      top = top.clamp(topSafe, bottomSafe - pillHeight);
      dropoffLabel = Positioned(
        left: left,
        top: top,
        child: _buildMapLabel(
          icon: Icons.location_on,
          title: 'DESTINO',
          address: widget.dropoffAddress,
          isPickup: false,
        ),
      );
    }

    return Stack(
      children: [
        if (pickupLabel != null) pickupLabel,
        if (dropoffLabel != null) dropoffLabel,
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

  /// Web: .vipRide__testSheet__icon — 48x48 circle with pulse rings
  Widget _buildPulsingIcon() {
    return SizedBox(
      width: 72,
      height: 72,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Outer ring — web ::before width:58px
          _AnimatedRing(size: 58, delay: 0.55, gold: _gold),
          // Inner ring — web ::after width:72px
          _AnimatedRing(size: 72, delay: 0.9, gold: _gold),
          // Core circle — web: 48x48
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // web: radial-gradient(circle at 38% 32%,rgba(255,255,255,.1),rgba(232,197,71,.07))
              gradient: RadialGradient(
                center: const Alignment(-0.24, -0.36),
                colors: [
                  Colors.white.withValues(alpha: 0.1),
                  _gold.withValues(alpha: 0.07),
                ],
              ),
              border: Border.all(
                color: _gold.withValues(alpha: 0.45),
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: _gold.withValues(alpha: 0.18),
                  blurRadius: 28,
                ),
              ],
            ),
            child: const Icon(Icons.directions_car, color: _gold, size: 24),
          ),
        ],
      ),
    );
  }

  /// Web: .vipRide__testBar--phase2 shimmer gold gradient
  Widget _buildShimmerBar() {
    return AnimatedBuilder(
      animation: _shimmerCtrl,
      builder: (_, __) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: Container(
            height: 3,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(2),
            ),
            child: FractionallySizedBox(
              widthFactor: 1.0,
              alignment: Alignment.centerLeft,
              child: ShaderMask(
                shaderCallback: (bounds) {
                  // web: linear-gradient(90deg,#B08800,#E8C547,#F5DC7A,#E8C547,#B08800)
                  // background-size:200% → shift from 100% to -100%
                  final shift = 1.0 - 2.0 * _shimmerCtrl.value;
                  return LinearGradient(
                    colors: const [
                      Color(0xFFB08800),
                      Color(0xFFE8C547),
                      Color(0xFFF5DC7A),
                      Color(0xFFE8C547),
                      Color(0xFFB08800),
                    ],
                    stops: const [0.0, 0.25, 0.5, 0.75, 1.0],
                    transform: GradientRotation(0),
                    begin: Alignment(shift - 1, 0),
                    end: Alignment(shift + 1, 0),
                  ).createShader(bounds);
                },
                blendMode: BlendMode.srcIn,
                child: Container(
                  height: 3,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        );
      },
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

/// Pulsing ring that animates scale + opacity (web: @keyframes vipTestPulse)
class _AnimatedRing extends StatefulWidget {
  final double size;
  final double delay; // seconds
  final Color gold;
  const _AnimatedRing({required this.size, required this.delay, required this.gold});

  @override
  State<_AnimatedRing> createState() => _AnimatedRingState();
}

class _AnimatedRingState extends State<_AnimatedRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );
    Future.delayed(Duration(milliseconds: (widget.delay * 1000).round()), () {
      if (mounted) _ctrl.repeat();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        // web: 0%{scale(.6);opacity:0} 15%{opacity:.55} 100%{scale(1.25);opacity:0}
        final t = _ctrl.value;
        final scale = 0.6 + 0.65 * t;
        final opacity = t < 0.15
            ? (t / 0.15) * 0.55
            : 0.55 * (1 - (t - 0.15) / 0.85);
        return Transform.scale(
          scale: scale,
          child: Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: widget.gold.withValues(alpha: 0.3),
                  width: 1.5,
                ),
              ),
            ),
          ),
        );
      },
    );
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
