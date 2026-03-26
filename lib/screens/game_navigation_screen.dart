import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:geolocator/geolocator.dart';

import '../config/mapbox_config.dart';
import '../config/map_theme.dart';
import '../models/lat_lng.dart';

/// Sistema de navegación tipo juego con estilo 3D isométrico
/// Características:
/// - Vista isométrica con pitch 55°
/// - Coche estilizado 3D con sombras
/// - Cámara cinemática con delay suave
/// - Ruta con efecto glow
/// - Movimiento interpolado 60 FPS
class GameNavigationScreen extends StatefulWidget {
  final LatLng destination;
  final List<LatLng>? routePoints;
  final String? destinationName;
  final VoidCallback? onArrival;

  const GameNavigationScreen({
    super.key,
    required this.destination,
    this.routePoints,
    this.destinationName,
    this.onArrival,
  });

  @override
  State<GameNavigationScreen> createState() => _GameNavigationScreenState();
}

class _GameNavigationScreenState extends State<GameNavigationScreen>
    with TickerProviderStateMixin {
  // ── Mapbox ──
  mapbox.MapboxMap? _map;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PolylineAnnotationManager? _polylineAnnotMgr;
  mapbox.PointAnnotation? _carAnnot;

  // ── Car State ──
  LatLng _currentPos = const LatLng(0, 0);
  double _currentBearing = 0;
  double _currentSpeed = 0; // m/s
  ui.Image? _carImage;
  Uint8List? _carImageBytes;

  // ── Interpolation ──
  final MovementInterpolator _interpolator = MovementInterpolator(
    lerpFactor: 0.12, // 0.08-0.15 para suavidad
    rotationLerp: 0.18,
  );

  // ── Camera ──
  final SmoothCameraController _cameraController = SmoothCameraController(
    followDelay: const Duration(milliseconds: 350),
    positionOffset: const Offset(0, 0.35), // Car en lower third
  );

  // ── Route ──
  List<LatLng> _route = [];
  double _distanceRemaining = 0;
  int _etaSeconds = 0;

  // ── Animation ──
  Timer? _animationTimer;
  StreamSubscription<Position>? _gpsSubscription;
  bool _isNavigating = false;

  // ── Effects ──
  double _turnTilt = 0; // Tilt adicional al girar
  double _speedZoom = 17.0; // Zoom dinámico por velocidad

  @override
  void initState() {
    super.initState();
    _initializeLocation();
    _generateCarImage();
    _setupRoute();
  }

  @override
  void dispose() {
    _animationTimer?.cancel();
    _gpsSubscription?.cancel();
    _interpolator.dispose();
    _cameraController.dispose();
    super.dispose();
  }

  Future<void> _initializeLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
        ),
      );
      _currentPos = LatLng(position.latitude, position.longitude);
      _interpolator.teleport(_currentPos, 0);
      _startNavigation();
    } catch (e) {
      debugPrint('[GameNav] GPS init error: $e');
    }
  }

  void _startNavigation() {
    _isNavigating = true;

    // GPS Stream con alta frecuencia
    _gpsSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1, // Cada metro
      ),
    ).listen(_onGPSUpdate);

    // Animation loop 60 FPS
    _animationTimer = Timer.periodic(
      const Duration(milliseconds: 16), // ~60 FPS
      (_) => _onAnimationTick(),
    );
  }

  void _onGPSUpdate(Position pos) {
    if (!_isNavigating) return;

    final newPos = LatLng(pos.latitude, pos.longitude);
    final speed = pos.speed; // m/s

    // Calcular bearing desde el movimiento
    double bearing = _currentBearing;
    if (speed > 0.5) {
      bearing = _calculateBearing(_currentPos, newPos);
    } else {
      bearing = pos.heading; // Fallback a compass
    }

    // Push al interpolador
    _interpolator.pushTarget(
      position: newPos,
      bearing: bearing,
      speed: speed,
    );

    _currentSpeed = speed;
  }

  void _onAnimationTick() {
    if (!mounted || !_isNavigating) return;

    // Obtener valores interpolados
    final interpolated = _interpolator.tick();

    // Actualizar estado del coche
    setState(() {
      _currentPos = interpolated.position;
      _currentBearing = interpolated.bearing;
    });

    // Calcular efectos dinámicos
    _calculateDynamicEffects(interpolated);

    // Actualizar annotations
    _updateCarAnnotation();

    // Actualizar cámara cinemática
    _updateCamera(interpolated);

    // Calcular distancia y ETA
    _updateNavigationStats();
  }

  void _calculateDynamicEffects(InterpolatedValues values) {
    // Turn tilt: detectar giros bruscos
    final turnRate = values.angularVelocity.abs();
    final targetTilt = turnRate > 15 ? 8.0 : 0.0;
    _turnTilt = _lerp(_turnTilt, targetTilt, 0.1);

    // Speed zoom: más velocidad = más zoom out
    final speedKmh = values.speed * 3.6;
    double targetZoom = 17.0;
    if (speedKmh > 80) { targetZoom = 16.0; }
    else if (speedKmh > 50) { targetZoom = 16.5; }
    else if (speedKmh < 10) { targetZoom = 18.0; }

    _speedZoom = _lerp(_speedZoom, targetZoom, 0.05);
  }

  void _updateCamera(InterpolatedValues values) {
    final camera = _cameraController.calculateCamera(
      carPosition: values.position,
      carBearing: values.bearing,
      turnTilt: _turnTilt,
      speedZoom: _speedZoom,
    );

    _map?.setCamera(camera);
  }

  Future<void> _updateCarAnnotation() async {
    final mgr = _pointAnnotMgr;
    if (mgr == null || _carImageBytes == null) return;

    final opts = mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(
        coordinates: mapbox.Position(_currentPos.longitude, _currentPos.latitude),
      ),
      image: _carImageBytes,
      iconRotate: _currentBearing,
      iconSize: 1.2,
    );

    if (_carAnnot == null) {
      _carAnnot = await mgr.create(opts);
    } else {
      _carAnnot!.geometry = mapbox.Point(
        coordinates: mapbox.Position(_currentPos.longitude, _currentPos.latitude),
      );
      _carAnnot!.iconRotate = _currentBearing;
      await mgr.update(_carAnnot!);
    }
  }

  void _updateNavigationStats() {
    final dist = _haversine(_currentPos, widget.destination);
    _distanceRemaining = dist;

    // ETA basada en velocidad actual
    final speedKmh = _currentSpeed * 3.6;
    if (speedKmh > 5) {
      final hours = dist / speedKmh;
      _etaSeconds = (hours * 3600).round();
    } else {
      _etaSeconds = (dist / 30 * 3600).round(); // Asumir 30 km/h si parado
    }

    // Check arrival
    if (dist < 0.05 && widget.onArrival != null) { // 50m
      widget.onArrival!();
    }
  }

  double _calculateBearing(LatLng from, LatLng to) {
    final lat1 = _toRadians(from.latitude);
    final lat2 = _toRadians(to.latitude);
    final dLng = _toRadians(to.longitude - from.longitude);

    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);

    final bearing = math.atan2(y, x);
    return (_toDegrees(bearing) + 360) % 360;
  }

  double _haversine(LatLng a, LatLng b) {
    const R = 6371; // km
    final lat1 = _toRadians(a.latitude);
    final lat2 = _toRadians(b.latitude);
    final dLat = _toRadians(b.latitude - a.latitude);
    final dLng = _toRadians(b.longitude - a.longitude);

    final x = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) * math.cos(lat2) * math.sin(dLng / 2) * math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(x), math.sqrt(1 - x));

    return R * c;
  }

  double _toRadians(double degrees) => degrees * math.pi / 180;
  double _toDegrees(double radians) => radians * 180 / math.pi;
  double _lerp(double a, double b, double t) => a + (b - a) * t;

  Future<void> _generateCarImage() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    const size = Size(120, 200);

    // Dibujar coche estilizado 3D
    await _drawGameCar(canvas, size);

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.toInt(), size.height.toInt());

    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData != null) {
      setState(() {
        _carImageBytes = byteData.buffer.asUint8List();
      });
    }
  }

  Future<void> _drawGameCar(Canvas canvas, Size size) async {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // ── Sombra proyectada (efecto 3D) ──
    final shadowPath = Path()
      ..moveTo(cx - 35, cy + 70)
      ..lineTo(cx + 35, cy + 70)
      ..lineTo(cx + 40, cy + 85)
      ..lineTo(cx - 40, cy + 85)
      ..close();

    canvas.drawPath(
      shadowPath,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15),
    );

    // ── Cuerpo principal (forma trapezoidal isométrica) ──
    final bodyPaint = Paint()
      ..color = const Color(0xFF5BA3F5) // Azul brillante
      ..style = PaintingStyle.fill;

    final bodyPath = Path()
      // Parte trasera (más ancha)
      ..moveTo(cx - 40, cy + 50)
      ..quadraticBezierTo(cx - 45, cy + 20, cx - 35, cy - 10)
      // Lado izquierdo
      ..quadraticBezierTo(cx - 30, cy - 40, cx - 25, cy - 60)
      // Capó (delgado)
      ..lineTo(cx, cy - 75)
      ..lineTo(cx + 25, cy - 60)
      // Lado derecho
      ..quadraticBezierTo(cx + 30, cy - 40, cx + 35, cy - 10)
      ..quadraticBezierTo(cx + 45, cy + 20, cx + 40, cy + 50)
      // Curva trasera
      ..quadraticBezierTo(cx, cy + 65, cx - 40, cy + 50)
      ..close();

    canvas.drawPath(bodyPath, bodyPaint);

    // ── Degradado en el cuerpo (efecto 3D) ──
    final gradientPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xFF7AB8F7).withValues(alpha: 0.8),
          const Color(0xFF4A90E2).withValues(alpha: 0.3),
        ],
      ).createShader(Rect.fromLTWH(0, cy - 80, size.width, 140));

    canvas.drawPath(bodyPath, gradientPaint);

    // ── Techo (más claro, efecto isométrico) ──
    final roofPath = Path()
      ..moveTo(cx - 20, cy - 10)
      ..lineTo(cx - 18, cy - 45)
      ..lineTo(cx, cy - 55)
      ..lineTo(cx + 18, cy - 45)
      ..lineTo(cx + 20, cy - 10)
      ..quadraticBezierTo(cx, cy - 5, cx - 20, cy - 10)
      ..close();

    canvas.drawPath(
      roofPath,
      Paint()..color = const Color(0xFF8AC4F8),
    );

    // ── Parabrisas ──
    final windshieldPath = Path()
      ..moveTo(cx - 18, cy - 42)
      ..lineTo(cx, cy - 52)
      ..lineTo(cx + 18, cy - 42)
      ..lineTo(cx + 16, cy - 20)
      ..lineTo(cx - 16, cy - 20)
      ..close();

    canvas.drawPath(
      windshieldPath,
      Paint()
        ..color = const Color(0xFF1A3A5C)
        ..style = PaintingStyle.fill,
    );

    // Reflejo en parabrisas
    canvas.drawPath(
      windshieldPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.4),
            Colors.transparent,
          ],
        ).createShader(Rect.fromLTWH(cx - 18, cy - 52, 36, 32)),
    );

    // ── Faros delanteros (blancos brillantes) ──
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx - 20, cy - 65), width: 12, height: 8),
        const Radius.circular(2),
      ),
      Paint()..color = const Color(0xFFE8F4FF),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx + 20, cy - 65), width: 12, height: 8),
        const Radius.circular(2),
      ),
      Paint()..color = const Color(0xFFE8F4FF),
    );

    // ── Luces traseras (rojas) ──
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx - 25, cy + 55), width: 15, height: 10),
        const Radius.circular(3),
      ),
      Paint()..color = const Color(0xFFFF4444),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx + 25, cy + 55), width: 15, height: 10),
        const Radius.circular(3),
      ),
      Paint()..color = const Color(0xFFFF4444),
    );

    // ── Ruedas (negras con detalle) ──
    for (final offset in [
      Offset(cx - 32, cy + 25), // Trasera izq
      Offset(cx + 32, cy + 25), // Trasera der
      Offset(cx - 22, cy - 45), // Delantera izq
      Offset(cx + 22, cy - 45), // Delantera der
    ]) {
      // Neumático
      canvas.drawOval(
        Rect.fromCenter(center: offset, width: 18, height: 24),
        Paint()..color = const Color(0xFF1A1A1A),
      );
      // Llanta
      canvas.drawOval(
        Rect.fromCenter(center: offset, width: 10, height: 14),
        Paint()..color = const Color(0xFF444444),
      );
    }

    // ── Línea de contorno (outline) ──
    canvas.drawPath(
      bodyPath,
      Paint()
        ..color = const Color(0xFF2E5A8C)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  void _setupRoute() {
    if (widget.routePoints != null && widget.routePoints!.isNotEmpty) {
      _route = widget.routePoints!;
    }
  }

  Future<void> _drawRoute() async {
    final mgr = _polylineAnnotMgr;
    if (mgr == null || _route.length < 2) return;

    final coords = _route.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    final geo = mapbox.LineString(coordinates: coords);

    // Layer 1: Outer glow — wide, diffused halo
    await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: geo,
      lineColor: const Color(0xFFFFD700).withValues(alpha: 0.18).toARGB32(),
      lineWidth: 18.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));
    // Layer 2: Inner glow — warm transition
    await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: geo,
      lineColor: const Color(0xFFFFE566).withValues(alpha: 0.28).toARGB32(),
      lineWidth: 10.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));
    // Layer 3: Main gold line — sharp, crisp
    await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: geo,
      lineColor: const Color(0xFFFFD700).toARGB32(),
      lineWidth: 4.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: Stack(
        children: [
          // ── MAPA 3D ──
          Positioned.fill(
            child: RepaintBoundary(
              child: mapbox.MapWidget(
              styleUri: MapboxConfig.styleNavigation,
              cameraOptions: mapbox.CameraOptions(
                center: mapbox.Point(
                  coordinates: mapbox.Position(_currentPos.longitude, _currentPos.latitude),
                ),
                zoom: _speedZoom,
                pitch: 55.0,
                bearing: _currentBearing,
              ),
              onMapCreated: (ctrl) async {
                _map = ctrl;
                ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
                ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
                ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
                ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));
                _pointAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
                _polylineAnnotMgr = await ctrl.annotations.createPolylineAnnotationManager(
                  below: "road-label",
                );
                await _drawRoute();
              },
              onStyleLoadedListener: (_) async {
                if (_map != null) await MapTheme.applyNavyGold(_map!);
              },
              onScrollListener: (_) {
                // Usuario movió el mapa - opcional: pausar follow temporalmente
              },
            ),
            ),
          ),

          // ── EFECTO DE VELOCIDAD (motion blur sutil) ──
          if (_currentSpeed > 15) // > 54 km/h
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.center,
                      radius: 1.5,
                      colors: [
                        Colors.transparent,
                        Colors.blue.withValues(alpha: 0.03 * (_currentSpeed / 30).clamp(0, 1)),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // ── UI SUPERIOR ──
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 16,
            right: 16,
            child: _buildTopUI(),
          ),

          // ── UI INFERIOR (instrucciones) ──
          Positioned(
            bottom: 32,
            left: 16,
            right: 16,
            child: _buildBottomUI(),
          ),

          // ── BOTÓN CENTRAR ──
          Positioned(
            bottom: 140,
            right: 16,
            child: _buildRecenterButton(),
          ),
        ],
      ),
    );
  }

  Widget _buildTopUI() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1E2E).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2A3A5C), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          // ETA
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _formatETA(_etaSeconds),
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF5BA3F5),
                ),
              ),
              Text(
                '${_distanceRemaining.toStringAsFixed(1)} km remaining',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
          const Spacer(),
          // Velocidad
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF0A2463),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${(_currentSpeed * 3.6).toInt()}',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const Text(
                  'km/h',
                  style: TextStyle(fontSize: 10, color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomUI() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1E2E).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF2A3A5C), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Flecha de dirección
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFF5BA3F5),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF5BA3F5).withValues(alpha: 0.4),
                      blurRadius: 12,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.arrow_upward,
                  color: Colors.white,
                  size: 32,
                ),
              ),
              const SizedBox(width: 16),
              // Instrucción
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Continue straight',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (widget.destinationName != null)
                      Text(
                        'to ${widget.destinationName}',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white.withValues(alpha: 0.6),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecenterButton() {
    return GestureDetector(
      onTap: () {
        _cameraController.reset();
      },
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: const Color(0xFF1A1E2E).withValues(alpha: 0.95),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFF2A3A5C)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 12,
            ),
          ],
        ),
        child: const Icon(
          Icons.my_location,
          color: Color(0xFF5BA3F5),
        ),
      ),
    );
  }

  String _formatETA(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final mins = (seconds / 60).ceil();
    if (mins < 60) return '${mins}m';
    final hours = mins ~/ 60;
    final remMins = mins % 60;
    return '${hours}h ${remMins}m';
  }
}

/// ── INTERPOLADOR DE MOVIMIENTO (60 FPS) ──
class MovementInterpolator {
  final double lerpFactor;
  final double rotationLerp;

  LatLng _currentPos = const LatLng(0, 0);
  double _currentBearing = 0;
  final double _currentSpeed = 0;

  LatLng _targetPos = const LatLng(0, 0);
  double _targetBearing = 0;
  double _targetSpeed = 0;

  double _angularVelocity = 0;
  double _lastBearing = 0;

  MovementInterpolator({
    this.lerpFactor = 0.12,
    this.rotationLerp = 0.18,
  });

  void teleport(LatLng pos, double bearing) {
    _currentPos = pos;
    _targetPos = pos;
    _currentBearing = bearing;
    _targetBearing = bearing;
  }

  void pushTarget({
    required LatLng position,
    required double bearing,
    double speed = 0,
  }) {
    _targetPos = position;
    _targetSpeed = speed;

    // Calcular diferencia angular mínima
    double deltaBearing = bearing - _targetBearing;
    while (deltaBearing > 180) { deltaBearing -= 360; }
    while (deltaBearing < -180) { deltaBearing += 360; }
    _targetBearing = _targetBearing + deltaBearing;
  }

  InterpolatedValues tick() {
    // Interpolar posición
    _currentPos = LatLng(
      _lerp(_currentPos.latitude, _targetPos.latitude, lerpFactor),
      _lerp(_currentPos.longitude, _targetPos.longitude, lerpFactor),
    );

    // Interpolar bearing
    _currentBearing = _lerpAngle(_currentBearing, _targetBearing, rotationLerp);

    // Calcular velocidad angular
    _angularVelocity = (_currentBearing - _lastBearing).abs();
    _lastBearing = _currentBearing;

    return InterpolatedValues(
      position: _currentPos,
      bearing: _currentBearing % 360,
      speed: _currentSpeed,
      angularVelocity: _angularVelocity,
    );
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;

  double _lerpAngle(double a, double b, double t) {
    double diff = b - a;
    while (diff > 180) { diff -= 360; }
    while (diff < -180) { diff += 360; }
    return a + diff * t;
  }

  void dispose() {}
}

class InterpolatedValues {
  final LatLng position;
  final double bearing;
  final double speed;
  final double angularVelocity;

  InterpolatedValues({
    required this.position,
    required this.bearing,
    required this.speed,
    required this.angularVelocity,
  });
}

/// ── CONTROLADOR DE CÁMARA CINEMÁTICO ──
class SmoothCameraController {
  final Duration followDelay;
  final Offset positionOffset;

  LatLng _smoothedPosition = const LatLng(0, 0);
  double _smoothedBearing = 0;
  double _smoothedZoom = 17;
  double _smoothedTilt = 55;

  SmoothCameraController({
    this.followDelay = const Duration(milliseconds: 350),
    this.positionOffset = const Offset(0, 0.35),
  });

  mapbox.CameraOptions calculateCamera({
    required LatLng carPosition,
    required double carBearing,
    double turnTilt = 0,
    double speedZoom = 17,
  }) {
    // Offset para mantener coche en lower third
    final offsetLat = positionOffset.dy * 0.0003 * math.cos(_toRadians(carBearing));
    final offsetLng = positionOffset.dy * 0.0003 * math.sin(_toRadians(carBearing));

    final targetPos = LatLng(
      carPosition.latitude - offsetLat,
      carPosition.longitude - offsetLng,
    );

    // Smooth follow
    _smoothedPosition = LatLng(
      _lerp(_smoothedPosition.latitude, targetPos.latitude, 0.08),
      _lerp(_smoothedPosition.longitude, targetPos.longitude, 0.08),
    );

    _smoothedBearing = _lerpAngle(_smoothedBearing, carBearing, 0.06);
    _smoothedZoom = _lerp(_smoothedZoom, speedZoom, 0.03);
    _smoothedTilt = _lerp(_smoothedTilt, 55 + turnTilt, 0.05);

    return mapbox.CameraOptions(
      center: mapbox.Point(
        coordinates: mapbox.Position(
          _smoothedPosition.longitude,
          _smoothedPosition.latitude,
        ),
      ),
      zoom: _smoothedZoom,
      bearing: _smoothedBearing,
      pitch: _smoothedTilt,
    );
  }

  void reset() {
    _smoothedPosition = const LatLng(0, 0);
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;

  double _lerpAngle(double a, double b, double t) {
    double diff = b - a;
    while (diff > 180) { 
      diff -= 360; 
    }
    while (diff < -180) { 
      diff += 360; 
    }
    return a + diff * t;
  }

  double _toRadians(double degrees) => degrees * math.pi / 180;

  void dispose() {}
}
