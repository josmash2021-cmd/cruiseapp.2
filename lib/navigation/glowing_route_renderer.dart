import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../models/lat_lng.dart';

/// Sistema de renderizado de rutas con efecto GLOW tipo juego
/// Crea polilíneas gruesas con glow/bloom visual
class GlowingRouteRenderer {
  /// Colores predefinidos para el glow
  static const Color _glowBlue = Color(0xFF5BA3F5);
  static const Color _glowCyan = Color(0xFF00E5FF);
  static const Color _glowPurple = Color(0xFF9D4EDD);
  static const Color _glowGold = Color(0xFFE8C547);

  /// Renderiza ruta con múltiples capas para efecto de profundidad
  static Future<void> renderGlowingRoute({
    required mapbox.PolylineAnnotationManager manager,
    required List<LatLng> points,
    RouteGlowStyle style = RouteGlowStyle.blue,
    double progress = 1.0, // 0.0 - 1.0 para animación de progreso
  }) async {
    if (points.length < 2) return;

    final coords = points.map((p) =>
      mapbox.Position(p.longitude, p.latitude)
    ).toList();

    final palette = _getGlowPalette(style);

    // Capa 1: Glow exterior (más ancho, difuminado)
    await manager.create(mapbox.PolylineAnnotationOptions(
      geometry: mapbox.LineString(coordinates: coords),
      lineColor: palette.glow.withAlpha(60).toARGB32(),
      lineWidth: 24.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));

    // Capa 2: Glow medio
    await manager.create(mapbox.PolylineAnnotationOptions(
      geometry: mapbox.LineString(coordinates: coords),
      lineColor: palette.glow.withAlpha(120).toARGB32(),
      lineWidth: 16.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));

    // Capa 3: Línea principal brillante
    await manager.create(mapbox.PolylineAnnotationOptions(
      geometry: mapbox.LineString(coordinates: coords),
      lineColor: palette.core.toARGB32(),
      lineWidth: 8.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));

    // Capa 4: Centro brillante (línea blanca/azul muy clara)
    await manager.create(mapbox.PolylineAnnotationOptions(
      geometry: mapbox.LineString(coordinates: coords),
      lineColor: palette.highlight.toARGB32(),
      lineWidth: 3.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));

    // Si hay progreso parcial, renderizar "cabeza" de la ruta
    if (progress < 1.0 && progress > 0) {
      final progressIndex = (points.length * progress).round();
      if (progressIndex > 0 && progressIndex < points.length) {
        final traveledPoints = points.sublist(0, progressIndex);
        final traveledCoords = traveledPoints.map((p) =>
          mapbox.Position(p.longitude, p.latitude)
        ).toList();

        // Ruta ya recorrida (más opaca)
        await manager.create(mapbox.PolylineAnnotationOptions(
          geometry: mapbox.LineString(coordinates: traveledCoords),
          lineColor: palette.core.withOpacity(0.5).toARGB32(),
          lineWidth: 6.0,
          lineJoin: mapbox.LineJoin.ROUND,
        ));
      }
    }
  }

  /// Renderiza una ruta animada tipo "carrera" con segmentos
  static Future<void> renderAnimatedRaceRoute({
    required mapbox.PolylineAnnotationManager manager,
    required List<LatLng> points,
    RouteGlowStyle style = RouteGlowStyle.cyan,
    double dashLength = 50, // metros aprox
    double gapLength = 30,
  }) async {
    if (points.length < 2) return;

    final palette = _getGlowPalette(style);

    // Crear línea segmentada tipo dash
    final segments = _createDashSegments(points, dashLength, gapLength);

    for (int i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final coords = segment.map((p) =>
        mapbox.Position(p.longitude, p.latitude)
      ).toList();

      // Alternar colores para efecto "carrera"
      final isEven = i % 2 == 0;
      final color = isEven ? palette.core : palette.highlight;
      final width = isEven ? 10.0 : 6.0;

      await manager.create(mapbox.PolylineAnnotationOptions(
        geometry: mapbox.LineString(coordinates: coords),
        lineColor: color.toARGB32(),
        lineWidth: width,
        lineJoin: mapbox.LineJoin.ROUND,
      ));
    }
  }

  /// Renderiza ruta con efecto de pulso/heartbeat
  static Future<List<mapbox.PolylineAnnotation>> renderPulsingRoute({
    required mapbox.PolylineAnnotationManager manager,
    required List<LatLng> points,
    RouteGlowStyle style = RouteGlowStyle.purple,
  }) async {
    if (points.length < 2) return [];

    final coords = points.map((p) =>
      mapbox.Position(p.longitude, p.latitude)
    ).toList();

    final palette = _getGlowPalette(style);
    final annotations = <mapbox.PolylineAnnotation>[];

    // Capa de glow (la que pulsará)
    final glowAnnotation = await manager.create(mapbox.PolylineAnnotationOptions(
      geometry: mapbox.LineString(coordinates: coords),
      lineColor: palette.glow.withAlpha(100).toARGB32(),
      lineWidth: 20.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));
    annotations.add(glowAnnotation);

    // Línea principal
    final coreAnnotation = await manager.create(mapbox.PolylineAnnotationOptions(
      geometry: mapbox.LineString(coordinates: coords),
      lineColor: palette.core.toARGB32(),
      lineWidth: 8.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));
    annotations.add(coreAnnotation);

    // Centro brillante
    final highlightAnnotation = await manager.create(mapbox.PolylineAnnotationOptions(
      geometry: mapbox.LineString(coordinates: coords),
      lineColor: palette.highlight.toARGB32(),
      lineWidth: 3.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));
    annotations.add(highlightAnnotation);

    return annotations;
  }

  /// Renderiza ruta tipo "laser" (línea muy brillante)
  static Future<void> renderLaserRoute({
    required mapbox.PolylineAnnotationManager manager,
    required List<LatLng> points,
    RouteGlowStyle style = RouteGlowStyle.cyan,
  }) async {
    if (points.length < 2) return;

    final coords = points.map((p) =>
      mapbox.Position(p.longitude, p.latitude)
    ).toList();

    final palette = _getGlowPalette(style);

    // Glow intenso
    await manager.create(mapbox.PolylineAnnotationOptions(
      geometry: mapbox.LineString(coordinates: coords),
      lineColor: palette.glow.withAlpha(180).toARGB32(),
      lineWidth: 18.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));

    // Línea laser brillante
    await manager.create(mapbox.PolylineAnnotationOptions(
      geometry: mapbox.LineString(coordinates: coords),
      lineColor: palette.highlight.toARGB32(),
      lineWidth: 5.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));
  }

  /// Crea una flecha direccional 3D en un punto específico
  static Future<void> renderDirectionArrow({
    required mapbox.PointAnnotationManager manager,
    required LatLng position,
    required double bearing,
    RouteGlowStyle style = RouteGlowStyle.blue,
  }) async {
    final palette = _getGlowPalette(style);

    // Generar imagen de flecha
    final arrowBytes = await _generateArrowImage(palette);

    await manager.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(
        coordinates: mapbox.Position(position.longitude, position.latitude),
      ),
      image: arrowBytes,
      iconRotate: bearing,
      iconSize: 1.5,
    ));
  }

  /// Genera imagen de flecha direccional
  static Future<Uint8List> _generateArrowImage(GlowPalette palette) async {
    const size = Size(60, 80);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final cx = size.width / 2;
    final cy = size.height / 2;

    // Glow de fondo
    final glowPaint = Paint()
      ..color = palette.glow.withOpacity(0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15);

    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy), width: 50, height: 70),
      glowPaint,
    );

    // Flecha triangular
    final arrowPath = Path()
      ..moveTo(cx, cy - 35)
      ..lineTo(cx + 20, cy + 15)
      ..lineTo(cx + 8, cy + 15)
      ..lineTo(cx + 8, cy + 35)
      ..lineTo(cx - 8, cy + 35)
      ..lineTo(cx - 8, cy + 15)
      ..lineTo(cx - 20, cy + 15)
      ..close();

    // Relleno
    canvas.drawPath(
      arrowPath,
      Paint()..color = palette.core,
    );

    // Highlight
    canvas.drawPath(
      arrowPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            palette.highlight,
            Colors.transparent,
          ],
        ).createShader(Rect.fromLTWH(0, cy - 35, size.width, 70)),
    );

    // Contorno
    canvas.drawPath(
      arrowPath,
      Paint()
        ..color = palette.highlight
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(
      size.width.toInt(),
      size.height.toInt(),
    );

    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  /// Divide puntos en segmentos tipo dash
  static List<List<LatLng>> _createDashSegments(
    List<LatLng> points,
    double dashLength,
    double gapLength,
  ) {
    final segments = <List<LatLng>>[];
    var currentSegment = <LatLng>[points[0]];
    var currentLength = 0.0;
    var isDash = true;

    for (int i = 1; i < points.length; i++) {
      final p1 = points[i - 1];
      final p2 = points[i];
      final dist = _haversineMeters(p1, p2);

      currentLength += dist;
      currentSegment.add(p2);

      final targetLength = isDash ? dashLength : gapLength;

      if (currentLength >= targetLength) {
        if (isDash) {
          segments.add(List.from(currentSegment));
        }
        currentSegment = [p2];
        currentLength = 0;
        isDash = !isDash;
      }
    }

    if (currentSegment.length > 1 && isDash) {
      segments.add(currentSegment);
    }

    return segments;
  }

  static double _haversineMeters(LatLng a, LatLng b) {
    const R = 6371000; // Radio de la Tierra en metros
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;

    final x = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) * math.cos(lat2) *
        math.sin(dLng / 2) * math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(x), math.sqrt(1 - x));

    return R * c;
  }

  static GlowPalette _getGlowPalette(RouteGlowStyle style) {
    switch (style) {
      case RouteGlowStyle.blue:
        return GlowPalette(
          glow: _glowBlue,
          core: const Color(0xFF4A90E2),
          highlight: const Color(0xFF7AB8F7),
        );
      case RouteGlowStyle.cyan:
        return GlowPalette(
          glow: _glowCyan,
          core: const Color(0xFF00BCD4),
          highlight: const Color(0xFF80DEEA),
        );
      case RouteGlowStyle.purple:
        return GlowPalette(
          glow: _glowPurple,
          core: const Color(0xFF7B1FA2),
          highlight: const Color(0xFFE1BEE7),
        );
      case RouteGlowStyle.gold:
        return GlowPalette(
          glow: _glowGold,
          core: const Color(0xFFFFA000),
          highlight: const Color(0xFFFFE082),
        );
    }
  }
}

enum RouteGlowStyle { blue, cyan, purple, gold }

class GlowPalette {
  final Color glow;
  final Color core;
  final Color highlight;

  GlowPalette({
    required this.glow,
    required this.core,
    required this.highlight,
  });
}
