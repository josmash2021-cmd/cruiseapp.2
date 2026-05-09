import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';
import '../widgets/map/circular_pin_renderer.dart';

/// ═══════════════════════════════════════════════════════════════════
///  TrackingMapAnnotations — Gestión de pins (pickup/dropoff) en el mapa
/// ═══════════════════════════════════════════════════════════════════
class TrackingMapAnnotations {
  TrackingMapAnnotations(this._pointAnnotMgr);

  final mapbox.PointAnnotationManager? _pointAnnotMgr;

  mapbox.PointAnnotation? _pickupAnnot;
  mapbox.PointAnnotation? _dropoffAnnot;

  Uint8List? _pickupPinBytes;
  Uint8List? _dropoffPinBytes;
  Uint8List? _pickupPinWithLabelBytes;
  Uint8List? _dropoffPinWithLabelBytes;

  bool _pickupLabelRevealed = false;
  bool _dropoffLabelRevealed = false;

  /// Carga los iconos de pins (pickup y dropoff)
  Future<void> loadPins({
    required String pickupLabel,
    required String dropoffLabel,
  }) async {
    _pickupPinBytes = await _renderGoldPin(isPickup: true, label: pickupLabel);
    _dropoffPinBytes = await _renderGoldPin(isPickup: false, label: dropoffLabel);

    if (pickupLabel.trim().isNotEmpty) {
      _pickupPinWithLabelBytes = await _renderGoldPinWithLabel(
        isPickup: true,
        label: pickupLabel,
      );
    }
    if (dropoffLabel.trim().isNotEmpty) {
      _dropoffPinWithLabelBytes = await _renderGoldPinWithLabel(
        isPickup: false,
        label: dropoffLabel,
      );
    }
  }

  /// Actualiza las anotaciones en el mapa
  Future<void> updateAnnotations({
    required LatLng pickupLatLng,
    required LatLng dropoffLatLng,
  }) async {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;

    // Pickup pin
    if (_pickupPinBytes != null) {
      if (_pickupAnnot == null) {
        _pickupAnnot = await mgr.create(
          mapbox.PointAnnotationOptions(
            geometry: mapbox.Point(
              coordinates: mapbox.Position(pickupLatLng.longitude, pickupLatLng.latitude),
            ),
            image: _pickupPinBytes,
            iconSize: 1.0,
            iconOffset: [0, 0],
          ),
        );
      } else {
        _pickupAnnot!.geometry = mapbox.Point(
          coordinates: mapbox.Position(pickupLatLng.longitude, pickupLatLng.latitude),
        );
        await mgr.update(_pickupAnnot!);
      }
    }

    // Dropoff pin
    if (_dropoffPinBytes != null) {
      if (_dropoffAnnot == null) {
        _dropoffAnnot = await mgr.create(
          mapbox.PointAnnotationOptions(
            geometry: mapbox.Point(
              coordinates: mapbox.Position(dropoffLatLng.longitude, dropoffLatLng.latitude),
            ),
            image: _dropoffPinBytes,
            iconSize: 1.0,
            iconOffset: [0, 0],
          ),
        );
      } else {
        _dropoffAnnot!.geometry = mapbox.Point(
          coordinates: mapbox.Position(dropoffLatLng.longitude, dropoffLatLng.latitude),
        );
        await mgr.update(_dropoffAnnot!);
      }
    }
  }

  /// Revela el label del pickup con animación spring
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

  /// Revela el label del dropoff con animación spring
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
}

enum _PinIcon { house, store, airplane, person }
