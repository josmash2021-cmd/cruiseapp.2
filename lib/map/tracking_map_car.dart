import 'dart:async';
import 'dart:math' as math;

import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';


/// ═══════════════════════════════════════════════════════════════════
///  TrackingMapCar — Gestión del icono del carro del conductor
/// ═══════════════════════════════════════════════════════════════════
class TrackingMapCar {
  TrackingMapCar({
    required this.map,
    required mapbox.PointAnnotationManager? carAnnotMgr,
  }) : _carAnnotMgr = carAnnotMgr;

  final mapbox.MapboxMap map;
  mapbox.PointAnnotationManager? _carAnnotMgr;

  mapbox.PointAnnotation? _carAnnot;
  Uint8List? _carPngBytes;
  bool _carAnnotCreating = false;
  bool _carPopDone = false;

  LatLng _driverPos = const LatLng(0, 0);
  final LatLng _animPos = const LatLng(0, 0);
  double _driverBearing = 0;

  final _kCarAnnotScale = 0.55;

  /// Carga el icono del carro según el tipo de viaje
  Future<void> loadCarIcon(String rideName) async {
    final rideNameLower = rideName.toLowerCase();
    String carAsset;

    if (rideNameLower.contains('vip') || rideNameLower.contains('suv') ||
        rideNameLower.contains('suburban') || rideNameLower.contains('luxury')) {
      carAsset = 'assets/images/car_suv.png';
    } else if (rideNameLower.contains('sedan') || rideNameLower.contains('premium') ||
        rideNameLower.contains('fusion')) {
      carAsset = 'assets/images/car_sedan.png';
    } else {
      carAsset = 'assets/images/car_economy.png';
    }

    debugPrint('[TrackingMapCar] rideName="$rideNameLower" → asset=$carAsset');

    try {
      final raw = await rootBundle.load(carAsset);
      _carPngBytes = await _resizePngForMap(raw.buffer.asUint8List(), maxDim: 240);
      debugPrint('[TrackingMapCar] loaded ${_carPngBytes!.length} PNG bytes');
    } catch (e) {
      debugPrint('[TrackingMapCar] FAILED to load $carAsset: $e');
      try {
        final raw = await rootBundle.load('assets/images/car_economy.png');
        _carPngBytes = await _resizePngForMap(raw.buffer.asUint8List(), maxDim: 240);
      } catch (e) {
        debugPrint('[TrackingMapCar] Fallback car load failed: $e');
      }
    }
  }

  /// Actualiza el manager de anotaciones (útil cuando se recrea el mapa)
  void setAnnotManager(mapbox.PointAnnotationManager? mgr) {
    _carAnnotMgr = mgr;
    // Reset annotation since manager changed
    _carAnnot = null;
    _carAnnotCreating = false;
  }

  /// Actualiza la posición del carro en el mapa
  Future<void> updatePosition(LatLng pos, {double bearing = 0}) async {
    _driverPos = pos;
    _driverBearing = bearing;

    // Skip if no valid position
    if (pos.latitude == 0 && pos.longitude == 0) return;

    if (_carAnnotCreating) return;
    if (_carPngBytes == null) return;

    final mgr = _carAnnotMgr;
    if (mgr == null) return;

    if (_carAnnot == null) {
      _carAnnotCreating = true;
      try {
        _carAnnot = await mgr.create(
          mapbox.PointAnnotationOptions(
            geometry: mapbox.Point(
              coordinates: mapbox.Position(pos.longitude, pos.latitude),
            ),
            image: _carPngBytes,
            iconSize: _carPopDone ? _kCarAnnotScale : 0.01,
            iconAnchor: mapbox.IconAnchor.CENTER,
            iconRotate: bearing,
            iconOffset: [0, 0],
          ),
        );
        // Pop-in animation on first creation
        if (!_carPopDone) {
          _carPopDone = true;
          _animateCarPopIn(mgr);
        }
      } catch (e) {
        debugPrint('[TrackingMapCar] Failed to create car annotation: $e');
      } finally {
        _carAnnotCreating = false;
      }
    } else {
      _carAnnot!.geometry = mapbox.Point(
        coordinates: mapbox.Position(pos.longitude, pos.latitude),
      );
      _carAnnot!.iconRotate = bearing;
      // Fire-and-forget: awaiting every frame serializes the animation behind
      // the Mapbox platform channel and produces stutter. Catch errors so a
      // stale annotation is recreated on the next valid position.
      try {
        mgr.update(_carAnnot!).catchError((e) {
          debugPrint('[TrackingMapCar] Failed to update car annotation: $e');
          if (_carAnnot != null) _carAnnot = null;
        });
      } catch (e) {
        debugPrint('[TrackingMapCar] Failed to update car annotation: $e');
        _carAnnot = null;
      }
    }
  }

  /// Pop-in animation for the car marker: 0.01 → 0.77 → 0.50 → 0.55 over 400ms
  void _animateCarPopIn(mapbox.PointAnnotationManager mgr) {
    if (_carAnnot == null) return;

    final startTime = DateTime.now();
    const durationMs = 400;

    Timer.periodic(const Duration(milliseconds: 16), (timer) {
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      final t = (elapsed / durationMs).clamp(0.0, 1.0);

      double scale;
      if (t < 0.35) {
        scale = 0.01 + (_kCarAnnotScale * 1.4 - 0.01) * (t / 0.35);
      } else if (t < 0.65) {
        scale = _kCarAnnotScale * 1.4 + (_kCarAnnotScale * 0.9 - _kCarAnnotScale * 1.4) * ((t - 0.35) / 0.3);
      } else {
        scale = _kCarAnnotScale * 0.9 + (_kCarAnnotScale - _kCarAnnotScale * 0.9) * ((t - 0.65) / 0.35);
      }

      try {
        mgr.update(_carAnnot!..iconSize = scale);
      } catch (_) {}

      if (t >= 1.0) timer.cancel();
    });
  }

  /// Limpia la anotación del carro
  Future<void> clear() async {
    final mgr = _carAnnotMgr;
    if (mgr == null || _carAnnot == null) return;
    try {
      await mgr.delete(_carAnnot!);
      _carAnnot = null;
      _carPopDone = false;
    } catch (e) {
      debugPrint('[TrackingMapCar] Failed to delete car annotation: $e');
    }
  }

  /// Reset para cuando se destruye y recrea el mapa
  void reset() {
    _carAnnot = null;
    _carAnnotCreating = false;
    _carPopDone = false;
  }

  /// Redimensiona un PNG para usar como icono de mapa
  Future<Uint8List> _resizePngForMap(Uint8List pngBytes, {int maxDim = 160}) async {
    final codec = await ui.instantiateImageCodec(pngBytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;

    final scale = maxDim / math.max(img.width, img.height);
    final newW = (img.width * scale).round().clamp(1, maxDim);
    final newH = (img.height * scale).round().clamp(1, maxDim);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, newW.toDouble(), newH.toDouble()));
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(0, 0, newW.toDouble(), newH.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();
    final resized = await picture.toImage(newW, newH);
    final byteData = await resized.toByteData(format: ui.ImageByteFormat.png);
    resized.dispose();
    picture.dispose();
    img.dispose();
    return byteData!.buffer.asUint8List();
  }

  // Getters
  LatLng get driverPos => _driverPos;
  LatLng get animPos => _animPos;
  double get driverBearing => _driverBearing;
  bool get hasIcon => _carPngBytes != null;
  bool get hasAnnotation => _carAnnot != null;
}
