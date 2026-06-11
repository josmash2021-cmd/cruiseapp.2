import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';
import '../widgets/map/circular_pin_renderer.dart';
import '../utils/mapbox_safe.dart';

/// ═══════════════════════════════════════════════════════════════════
///  TrackingMapAnnotations — Gestión de pins (pickup/dropoff) en el mapa
/// ═══════════════════════════════════════════════════════════════════
class TrackingMapAnnotations {
  TrackingMapAnnotations({
    required this.map,
    required mapbox.PointAnnotationManager? pointAnnotMgr,
  }) : _pointAnnotMgr = pointAnnotMgr;

  final mapbox.MapboxMap map;
  mapbox.PointAnnotationManager? _pointAnnotMgr;

  mapbox.PointAnnotation? _pickupAnnot;
  mapbox.PointAnnotation? _dropoffAnnot;

  Uint8List? _pickupPinBytes;
  Uint8List? _dropoffPinBytes;
  Uint8List? _pickupPinWithLabelBytes;
  Uint8List? _dropoffPinWithLabelBytes;

  bool _pickupLabelRevealed = false;
  bool _dropoffLabelRevealed = false;
  bool _dropoffPinAdded = false;

  Timer? _dropoffPopTimer;
  Timer? _pickupPopTimer;

  /// Actualiza el manager de anotaciones
  void setAnnotManager(mapbox.PointAnnotationManager? mgr) {
    _pointAnnotMgr = mgr;
    _pickupAnnot = null;
    _dropoffAnnot = null;
  }

  /// Carga los iconos de pins (pickup y dropoff)
  Future<void> loadPins({
    required String pickupLabel,
    required String dropoffLabel,
  }) async {
    try {
      _pickupPinBytes = await _renderGoldPin(isPickup: true, label: pickupLabel);
    } catch (e) {
      debugPrint('[TrackingMapAnnotations] Failed to render pickup pin: $e');
    }
    try {
      _dropoffPinBytes = await _renderGoldPin(isPickup: false, label: dropoffLabel);
    } catch (e) {
      debugPrint('[TrackingMapAnnotations] Failed to render dropoff pin: $e');
    }

    if (pickupLabel.trim().isNotEmpty) {
      try {
        _pickupPinWithLabelBytes = await _renderGoldPinWithLabel(
          isPickup: true,
          label: pickupLabel,
        );
      } catch (e) {
        debugPrint('[TrackingMapAnnotations] Failed to render pickup pin with label: $e');
      }
    }
    if (dropoffLabel.trim().isNotEmpty) {
      try {
        _dropoffPinWithLabelBytes = await _renderGoldPinWithLabel(
          isPickup: false,
          label: dropoffLabel,
        );
      } catch (e) {
        debugPrint('[TrackingMapAnnotations] Failed to render dropoff pin with label: $e');
      }
    }
  }

  /// Crea las anotaciones de pickup y dropoff en el mapa
  Future<void> createAnnotations({
    required LatLng pickupLatLng,
    required LatLng dropoffLatLng,
    bool animateDropoff = false,
  }) async {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;

    // Pickup pin
    if (_pickupPinBytes != null && _pickupAnnot == null) {
      final pickupPoint = safePoint(pickupLatLng.longitude, pickupLatLng.latitude);
      if (pickupPoint != null) {
        try {
          _pickupAnnot = await mgr.create(mapbox.PointAnnotationOptions(
            geometry: pickupPoint,
            image: _pickupPinBytes!,
            iconSize: 0.55,
            iconAnchor: mapbox.IconAnchor.BOTTOM,
            iconOffset: [0, 0],
          ));
        } catch (e) {
          debugPrint('[TrackingMapAnnotations] Failed to create pickup pin: $e');
        }
      }
    }

    // Dropoff pin
    if (_dropoffPinBytes != null && !_dropoffPinAdded) {
      _dropoffPinAdded = true;
      final dropoffPoint = safePoint(dropoffLatLng.longitude, dropoffLatLng.latitude);
      if (dropoffPoint != null) {
        try {
          final initialSize = animateDropoff ? 0.01 : 0.55;
          _dropoffAnnot = await mgr.create(mapbox.PointAnnotationOptions(
            geometry: dropoffPoint,
            image: _dropoffPinBytes!,
            iconSize: initialSize,
            iconAnchor: mapbox.IconAnchor.BOTTOM,
            iconOffset: [0, 0],
          ));
          if (animateDropoff) {
            _animateDropoffPinPop(mgr);
          }
        } catch (e) {
          debugPrint('[TrackingMapAnnotations] Failed to create dropoff pin: $e');
        }
      }
    }
  }

  /// Animación pop-in para el pin de dropoff
  void _animateDropoffPinPop(mapbox.PointAnnotationManager mgr) {
    if (_dropoffAnnot == null) return;
    _dropoffPopTimer?.cancel();

    final startTime = DateTime.now();
    const durationMs = 500;

    _dropoffPopTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      final t = (elapsed / durationMs).clamp(0.0, 1.0);

      double scale;
      if (t < 0.4) {
        scale = 0.01 + (0.62 - 0.01) * (t / 0.4);
      } else if (t < 0.7) {
        scale = 0.62 + (0.50 - 0.62) * ((t - 0.4) / 0.3);
      } else {
        scale = 0.50 + (0.55 - 0.50) * ((t - 0.7) / 0.3);
      }

      try {
        mgr.update(_dropoffAnnot!..iconSize = scale);
      } catch (_) {}

      if (t >= 1.0) timer.cancel();
    });
  }

  /// Revela el label del pickup
  Future<void> revealPickupLabel() async {
    if (_pickupLabelRevealed || _pickupAnnot == null || _pickupPinWithLabelBytes == null) return;
    _pickupLabelRevealed = true;
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    try {
      _pickupAnnot!.image = _pickupPinWithLabelBytes!;
      await mgr.update(_pickupAnnot!);
    } catch (e) {
      debugPrint('[TrackingMapAnnotations] Failed to reveal pickup label: $e');
    }
  }

  /// Revela el label del dropoff
  Future<void> revealDropoffLabel() async {
    if (_dropoffLabelRevealed || _dropoffAnnot == null || _dropoffPinWithLabelBytes == null) return;
    _dropoffLabelRevealed = true;
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    try {
      _dropoffAnnot!.image = _dropoffPinWithLabelBytes!;
      await mgr.update(_dropoffAnnot!);
    } catch (e) {
      debugPrint('[TrackingMapAnnotations] Failed to reveal dropoff label: $e');
    }
  }

  /// Pop-out animation para el pin de pickup (cuando el conductor llega)
  Future<void> popOutPickupPin() async {
    if (_pickupAnnot == null || _pointAnnotMgr == null) return;

    final mgr = _pointAnnotMgr!;
    final startTime = DateTime.now();
    const durationMs = 600;

    final completer = Completer<void>();
    _pickupPopTimer?.cancel();

    _pickupPopTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      final t = (elapsed / durationMs).clamp(0.0, 1.0);

      double scale;
      if (t < 0.35) {
        scale = 0.80 + (1.25 - 0.80) * (t / 0.35);
      } else {
        final st = (t - 0.35) / 0.65;
        scale = 1.25 * (1.0 - st * st);
      }

      try {
        mgr.update(_pickupAnnot!..iconSize = math.max(scale, 0.01));
      } catch (_) {}

      if (t >= 1.0) {
        timer.cancel();
        try { mgr.delete(_pickupAnnot!); } catch (_) {}
        _pickupAnnot = null;
        completer.complete();
      }
    });

    return completer.future;
  }

  /// Limpia todas las anotaciones
  Future<void> clear() async {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    if (_pickupAnnot != null) {
      try { await mgr.delete(_pickupAnnot!); } catch (_) {}
      _pickupAnnot = null;
    }
    if (_dropoffAnnot != null) {
      try { await mgr.delete(_dropoffAnnot!); } catch (_) {}
      _dropoffAnnot = null;
    }
    _dropoffPinAdded = false;
    _pickupLabelRevealed = false;
    _dropoffLabelRevealed = false;
  }

  /// Reset para recreación del mapa
  void reset() {
    _dropoffPopTimer?.cancel();
    _dropoffPopTimer = null;
    _pickupPopTimer?.cancel();
    _pickupPopTimer = null;
    _pickupAnnot = null;
    _dropoffAnnot = null;
    _dropoffPinAdded = false;
  }

  // ── Helpers privados ──

  Future<Uint8List> _renderGoldPin({
    required bool isPickup,
    String label = '',
  }) async {
    final iconType = _detectPinIcon(label);
    CircularPinIcon circIcon;
    switch (iconType) {
      case _PinIcon.house:    circIcon = CircularPinIcon.home; break;
      case _PinIcon.store:    circIcon = CircularPinIcon.store; break;
      case _PinIcon.airplane: circIcon = CircularPinIcon.airplane; break;
      case _PinIcon.person:
        circIcon = isPickup ? CircularPinIcon.person : CircularPinIcon.flag;
        break;
    }
    return renderCircularPinBytes(icon: circIcon, isPickup: isPickup, radius: 44);
  }

  Future<Uint8List> _renderGoldPinWithLabel({
    required bool isPickup,
    required String label,
  }) async {
    final pinBytes = await _renderGoldPin(isPickup: isPickup, label: label);
    final codec = await ui.instantiateImageCodec(pinBytes);
    final frame = await codec.getNextFrame();
    final pinImg = frame.image;

    String displayLabel = label;
    if (label.length > 20) {
      int cut = (label.length * 0.5).round();
      for (int i = cut; i >= 0; i--) {
        if (label[i] == ',' || label[i] == ' ') { cut = i; break; }
      }
      displayLabel = '${label.substring(0, cut).trimRight()}\u2026';
    }

    const pinDisplayW = 100.0;
    final pinDisplayH = pinDisplayW * pinImg.height / pinImg.width;
    final canvasH = pinDisplayH;

    final textPainter = TextPainter(
      text: TextSpan(
        text: displayLabel,
        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: Colors.white),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 450);

    const hPad = 14.0;
    const gap = 8.0;
    const dotSize = 10.0;
    final labelW = hPad + dotSize + gap + textPainter.width + hPad + 8;
    final labelH = math.min(70.0, canvasH * 0.60);
    const pinLabelGap = 8.0;

    final labelOnLeft = !isPickup;
    final rawW = pinDisplayW + pinLabelGap + labelW;

    double pinX, labelX;
    if (labelOnLeft) {
      labelX = 0;
      pinX = labelW + pinLabelGap;
    } else {
      pinX = 0;
      labelX = pinDisplayW + pinLabelGap;
    }

    final pinTipX = pinX + pinDisplayW / 2;
    final leftMargin = pinTipX;
    final rightMargin = rawW - pinTipX;
    final maxM = math.max(leftMargin, rightMargin);
    final leftPad = maxM - leftMargin;
    final paddedW = 2 * maxM;

    final adjPinX = pinX + leftPad;
    final adjLabelX = labelX + leftPad;
    final pinHeadCY = pinDisplayH * 0.32;
    final labelY = (pinHeadCY - labelH / 2).clamp(0.0, canvasH - labelH);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, paddedW, canvasH));

    final srcRect = Rect.fromLTWH(0, 0, pinImg.width.toDouble(), pinImg.height.toDouble());
    final dstRect = Rect.fromLTWH(adjPinX, 0, pinDisplayW, pinDisplayH);
    canvas.drawImageRect(pinImg, srcRect, dstRect, Paint());

    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(adjLabelX, labelY, labelW, labelH),
      const Radius.circular(10),
    );
    canvas.drawRRect(bgRect, Paint()..color = const Color(0xF01A1A1A));
    canvas.drawRRect(
      bgRect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.10)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    double x = adjLabelX + hPad;
    canvas.drawCircle(
      Offset(x + dotSize / 2, labelY + labelH / 2),
      dotSize / 2,
      Paint()..color = isPickup ? Colors.green : const Color(0xFFE8C547),
    );
    x += dotSize + gap;
    textPainter.paint(canvas, Offset(x, labelY + (labelH - textPainter.height) / 2));

    final picture = recorder.endRecording();
    final img = await picture.toImage(paddedW.ceil(), canvasH.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  _PinIcon _detectPinIcon(String label) {
    final l = label.toLowerCase();
    if (l.contains('airport') ||
        l.contains('terminal') ||
        RegExp(r'\b(mia|fll|jfk|lax|ord|atl|sfo|dfw|ewr|bos|iah|dca|phl|msp|dtw|sea|den|las|mco|clt)\b').hasMatch(l)) {
      return _PinIcon.airplane;
    }
    if (l.contains('store') || l.contains('shop') || l.contains('mall') ||
        l.contains('plaza') || l.contains('market') || l.contains('center') ||
        l.contains('restaurant') || l.contains('hotel') || l.contains('bar') ||
        l.contains('café') || l.contains('cafe') || l.contains('gym') ||
        l.contains('salon') || l.contains('office') || l.contains('hospital') ||
        l.contains('clinic') || l.contains('bank') || l.contains('pharmacy')) {
      return _PinIcon.store;
    }
    if (RegExp(r'^\d+\s').hasMatch(l) &&
        RegExp(r'\b(st|ave|rd|dr|ln|ct|blvd|way|pkwy|pl|cir|ter|loop)\b').hasMatch(l)) {
      return _PinIcon.house;
    }
    return _PinIcon.person;
  }

  // Getters
  bool get dropoffPinAdded => _dropoffPinAdded;
  bool get hasPins => _pickupPinBytes != null && _dropoffPinBytes != null;
}

enum _PinIcon { house, store, airplane, person }
