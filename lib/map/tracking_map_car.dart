import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';

/// ═══════════════════════════════════════════════════════════════════
///  TrackingMapCar — Gestión del icono del carro en el mapa
/// ═══════════════════════════════════════════════════════════════════
class TrackingMapCar {
  TrackingMapCar(this._carAnnotMgr);

  final mapbox.PointAnnotationManager? _carAnnotMgr;

  mapbox.PointAnnotation? _carAnnot;
  Uint8List? _carPngBytes;
  bool _carAnnotCreating = false;

  LatLng _driverPos = const LatLng(0, 0);
  LatLng _animPos = const LatLng(0, 0);
  double _driverBearing = 0;

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

    try {
      final raw = await rootBundle.load(carAsset);
      _carPngBytes = await _resizePngForMap(raw.buffer.asUint8List(), maxDim: 240);
    } catch (e) {
      try {
        final raw = await rootBundle.load('assets/images/car_economy.png');
        _carPngBytes = await _resizePngForMap(raw.buffer.asUint8List(), maxDim: 240);
      } catch (e) {
        debugPrint('[TrackingMapCar] Fallback car load failed: $e');
      }
    }
  }

  /// Actualiza la posición del carro en el mapa
  Future<void> updatePosition(LatLng pos, {double bearing = 0}) async {
    _driverPos = pos;
    _driverBearing = bearing;

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
            iconSize: 1.0,
            iconRotate: bearing,
          ),
        );
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
      try {
        await mgr.update(_carAnnot!);
      } catch (e) {
        debugPrint('[TrackingMapCar] Failed to update car annotation: $e');
      }
    }
  }

  /// Actualiza la posición animada (interpolación suave)
  Future<void> updateAnimatedPosition(LatLng pos, double progress) async {
    _animPos = pos;
    await updatePosition(pos);
  }

  /// Limpia la anotación del carro
  Future<void> clear() async {
    final mgr = _carAnnotMgr;
    if (mgr == null || _carAnnot == null) return;
    try {
      await mgr.delete(_carAnnot!);
      _carAnnot = null;
    } catch (e) {
      debugPrint('[TrackingMapCar] Failed to delete car annotation: $e');
    }
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
}
