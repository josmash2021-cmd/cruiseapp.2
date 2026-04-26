import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../config/mapbox_config.dart';
import '../config/map_theme.dart';
import '../models/lat_lng.dart';
import '../widgets/map/circular_pin_renderer.dart';
import 'home_screen.dart';

/// Confirmation screen shown after rider books a scheduled ride.
/// Full-screen map background with tilt, route, pins + centered content overlay.
class RideBookingConfirmedScreen extends StatefulWidget {
  final DateTime scheduledAt;
  final String pickupAddress;
  final String dropoffAddress;
  final String vehicleType;
  final double fare;
  final double? pickupLat;
  final double? pickupLng;
  final double? dropoffLat;
  final double? dropoffLng;
  final List<LatLng>? routePoints;

  const RideBookingConfirmedScreen({
    super.key,
    required this.scheduledAt,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.vehicleType,
    required this.fare,
    this.pickupLat,
    this.pickupLng,
    this.dropoffLat,
    this.dropoffLng,
    this.routePoints,
  });

  @override
  State<RideBookingConfirmedScreen> createState() =>
      _RideBookingConfirmedScreenState();
}

class _RideBookingConfirmedScreenState extends State<RideBookingConfirmedScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  late AnimationController _enterCtrl;
  late Animation<double> _checkScale;
  late Animation<double> _checkFade;
  late Animation<double> _textFade;
  late Animation<double> _cardSlide;

  late AnimationController _fadeOutCtrl;

  // Map tilt
  AnimationController? _tiltCtrl;
  Animation<double>? _tiltAnim;
  mapbox.MapboxMap? _mapCtrl;

  @override
  void initState() {
    super.initState();

    // ── Enter animations ──
    _enterCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    _checkScale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 1.2)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 55,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.2, end: 1.0)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 45,
      ),
    ]).animate(_enterCtrl);

    _checkFade = CurvedAnimation(
      parent: _enterCtrl,
      curve: const Interval(0.0, 0.4, curve: Curves.easeIn),
    );

    _textFade = CurvedAnimation(
      parent: _enterCtrl,
      curve: const Interval(0.25, 0.65, curve: Curves.easeOut),
    );

    _cardSlide = CurvedAnimation(
      parent: _enterCtrl,
      curve: const Interval(0.4, 0.85, curve: Curves.easeOutCubic),
    );

    // ── Fade-out to home ──
    _fadeOutCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    // Map tilt 0° → 20°
    _tiltCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _tiltAnim = Tween<double>(begin: 0.0, end: 20.0).animate(
      CurvedAnimation(parent: _tiltCtrl!, curve: Curves.easeInOutCubic),
    );

    _enterCtrl.forward();

    // Auto-navigate after 3.5 seconds
    Future.delayed(const Duration(milliseconds: 3500), () {
      if (!mounted) return;
      _fadeOutCtrl.forward().then((_) {
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          PageRouteBuilder(
            pageBuilder: (_, __, ___) => const HomeScreen(),
            transitionDuration: Duration.zero,
          ),
          (_) => false,
        );
      });
    });
  }

  @override
  void dispose() {
    _enterCtrl.dispose();
    _fadeOutCtrl.dispose();
    _tiltCtrl?.dispose();
    super.dispose();
  }

  bool get _hasMapData =>
      widget.pickupLat != null && widget.pickupLng != null;

  @override
  Widget build(BuildContext context) {
    final timeStr =
        DateFormat('EEEE, MMM d \u00b7 h:mm a').format(widget.scheduledAt);

    final midLat = (widget.pickupLat != null && widget.dropoffLat != null)
        ? (widget.pickupLat! + widget.dropoffLat!) / 2
        : widget.pickupLat ?? 0;
    final midLng = (widget.pickupLng != null && widget.dropoffLng != null)
        ? (widget.pickupLng! + widget.dropoffLng!) / 2
        : widget.pickupLng ?? 0;

    return AnimatedBuilder(
      animation: _fadeOutCtrl,
      builder: (context, child) => Opacity(
        opacity: 1.0 - _fadeOutCtrl.value,
        child: child,
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFF1A1A1F),
        body: Stack(
          fit: StackFit.expand,
          children: [
            // ── Map background ──
            if (_hasMapData)
              IgnorePointer(
                child: RepaintBoundary(
                  child: mapbox.MapWidget(
                    styleUri: MapboxConfig.styleDark,
                    cameraOptions: mapbox.CameraOptions(
                      center: mapbox.Point(
                        coordinates: mapbox.Position(midLng, midLat),
                      ),
                      zoom: 13.5,
                      pitch: 0.0,
                    ),
                    onMapCreated: _onMapCreated,
                  ),
                ),
              )
            else
              const ColoredBox(color: Colors.black),

            // ── Gradient overlay ──
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.25),
                      Colors.black.withValues(alpha: 0.65),
                      Colors.black.withValues(alpha: 0.85),
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              ),
            ),

            // ── Centered content ──
            SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // ── Animated gold check circle ──
                      AnimatedBuilder(
                        animation: _enterCtrl,
                        builder: (context, child) => FadeTransition(
                          opacity: _checkFade,
                          child: ScaleTransition(
                            scale: _checkScale,
                            child: child,
                          ),
                        ),
                        child: Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _gold.withValues(alpha: 0.12),
                            border: Border.all(color: _gold, width: 2.5),
                            boxShadow: [
                              BoxShadow(
                                color: _gold.withValues(alpha: 0.35),
                                blurRadius: 40,
                                spreadRadius: 8,
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.check_rounded,
                            color: _gold,
                            size: 54,
                          ),
                        ),
                      ),

                      const SizedBox(height: 28),

                      // ── Title ──
                      FadeTransition(
                        opacity: _textFade,
                        child: const Text(
                          'Ride Reservado',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _gold,
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ),

                      const SizedBox(height: 14),

                      // ── Subtitle ──
                      FadeTransition(
                        opacity: _textFade,
                        child: const Text(
                          'Te notificaremos cuando ya tengas\nun driver asignado',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white60,
                            fontSize: 15,
                            height: 1.5,
                          ),
                        ),
                      ),

                      const SizedBox(height: 32),

                      // ── Ride details card ──
                      SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.3),
                          end: Offset.zero,
                        ).animate(_cardSlide),
                        child: FadeTransition(
                          opacity: _cardSlide,
                          child: Container(
                            padding: const EdgeInsets.all(18),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1A1A1F),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: _gold.withValues(alpha: 0.15),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: _gold.withValues(alpha: 0.06),
                                  blurRadius: 20,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                _row(Icons.access_time_rounded, timeStr),
                                _divider(),
                                _row(Icons.location_on_rounded,
                                    widget.pickupAddress),
                                _divider(),
                                _row(Icons.flag_rounded, widget.dropoffAddress),
                                _divider(),
                                _row(
                                  Icons.directions_car_rounded,
                                  '${widget.vehicleType} \u00b7 \$${widget.fare.toStringAsFixed(2)}',
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // ── Status badge ──
                      FadeTransition(
                        opacity: _cardSlide,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 9,
                          ),
                          decoration: BoxDecoration(
                            color: _gold.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(20),
                            border:
                                Border.all(color: _gold.withValues(alpha: 0.3)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.schedule_rounded,
                                  color: _gold, size: 16),
                              SizedBox(width: 8),
                              Text(
                                'Pendiente de asignacion',
                                style: TextStyle(
                                  color: _gold,
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
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onMapCreated(mapbox.MapboxMap ctrl) async {
    _mapCtrl = ctrl;
    await MapTheme.applyNavyGold(ctrl);
    ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
    ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
    ctrl.attribution
        .updateSettings(mapbox.AttributionSettings(enabled: false));
    ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));

    // Animate tilt 0° → 20°
    if (_tiltAnim != null && _tiltCtrl != null) {
      _tiltAnim!.addListener(() {
        _mapCtrl?.setCamera(
          mapbox.CameraOptions(pitch: _tiltAnim!.value),
        );
      });
      _tiltCtrl!.forward();
    }

    // Add route polyline
    final routePts = widget.routePoints;
    if (routePts != null && routePts.length >= 2) {
      final polyMgr =
          await ctrl.annotations.createPolylineAnnotationManager();
      final coords = routePts
          .map((p) => mapbox.Position(p.longitude, p.latitude))
          .toList();
      await polyMgr.create(mapbox.PolylineAnnotationOptions(
        geometry: mapbox.LineString(coordinates: coords),
        lineColor: const Color(0xFFFFD700).toARGB32(),
        lineWidth: 5.0,
        lineJoin: mapbox.LineJoin.ROUND,
      ));
    }

    // Add smart pins
    final pointMgr =
        await ctrl.annotations.createPointAnnotationManager();
    try {
      await ctrl.style.setStyleLayerProperty(
          pointMgr.id, 'icon-pitch-alignment', 'viewport');
    } catch (_) {}
    try {
      await ctrl.style
          .setStyleLayerProperty(pointMgr.id, 'icon-allow-overlap', true);
    } catch (_) {}
    try {
      await ctrl.style
          .setStyleLayerProperty(pointMgr.id, 'icon-ignore-placement', true);
    } catch (_) {}
    try {
      await ctrl.style
          .setStyleLayerProperty(pointMgr.id, 'icon-anchor', 'bottom');
    } catch (_) {}

    // Pickup pin
    if (widget.pickupLat != null && widget.pickupLng != null) {
      final pickupBytes = await renderCircularPinBytes(
          icon: CircularPinIcon.person, isPickup: true, radius: 44);
      await pointMgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(
          coordinates:
              mapbox.Position(widget.pickupLng!, widget.pickupLat!),
        ),
        image: pickupBytes,
        iconSize: 0.65,
        iconAnchor: mapbox.IconAnchor.BOTTOM,
        iconOffset: [0, 0],
      ));
    }

    // Dropoff pin
    if (widget.dropoffLat != null && widget.dropoffLng != null) {
      final dropoffBytes = await renderCircularPinBytes(
          icon: CircularPinIcon.home, isPickup: false, radius: 44);
      await pointMgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(
          coordinates:
              mapbox.Position(widget.dropoffLng!, widget.dropoffLat!),
        ),
        image: dropoffBytes,
        iconSize: 0.65,
        iconAnchor: mapbox.IconAnchor.BOTTOM,
        iconOffset: [0, 0],
      ));
    }
  }

  Widget _row(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Icon(icon, color: _gold, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() =>
      Divider(color: Colors.white.withValues(alpha: 0.06), height: 1);
}
