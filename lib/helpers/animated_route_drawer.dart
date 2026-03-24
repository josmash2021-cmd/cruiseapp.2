import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../models/lat_lng.dart';

/// Progressive route drawing animation for Mapbox polylines.
///
/// Draws route points incrementally to create a fluid "Uber-like"
/// line-drawing effect. Supports multi-segment routes
/// (Driver→Pickup then Pickup→Dropoff) with a pause between segments.
class AnimatedRouteDrawer {
  AnimatedRouteDrawer._();

  /// Animate a single polyline segment progressively.
  ///
  /// [manager] – Mapbox polyline annotation manager.
  /// [points]  – Full list of route coordinates.
  /// [color]   – Line color (ARGB32 integer).
  /// [width]   – Line width in dp.
  /// [stepMs]  – Milliseconds between adding each point (lower = faster).
  /// [batchSize] – Points added per step (higher = faster for long routes).
  /// [onAnnotationCreated] – Called with the first PolylineAnnotation for cleanup.
  ///
  /// Returns the final PolylineAnnotation, or null if cancelled/empty.
  static Future<mapbox.PolylineAnnotation?> animateSegment({
    required mapbox.PolylineAnnotationManager manager,
    required List<LatLng> points,
    int color = 0xFFF5C518,
    double width = 8.0,
    int stepMs = 6,
    int batchSize = 3,
    void Function(mapbox.PolylineAnnotation)? onAnnotationCreated,
    CancellationToken? cancel,
  }) async {
    if (points.length < 2) return null;
    if (cancel?.isCancelled ?? false) return null;

    final allCoords = points
        .map((p) => mapbox.Position(p.longitude, p.latitude))
        .toList();

    // Start with first 2 points
    final drawn = <mapbox.Position>[allCoords[0], allCoords[1]];
    mapbox.PolylineAnnotation? annot;

    try {
      annot = await manager.create(mapbox.PolylineAnnotationOptions(
        geometry: mapbox.LineString(coordinates: List.of(drawn)),
        lineColor: color,
        lineWidth: width,
        lineJoin: mapbox.LineJoin.ROUND,
      ));
      onAnnotationCreated?.call(annot);
    } catch (_) {
      return null;
    }

    // Progressive drawing
    int i = 2;
    while (i < allCoords.length) {
      if (cancel?.isCancelled ?? false) return annot;

      // Add a batch of points
      final end = (i + batchSize).clamp(0, allCoords.length);
      for (int j = i; j < end; j++) {
        drawn.add(allCoords[j]);
      }
      i = end;

      // Update polyline in-place
      try {
        annot.geometry = mapbox.LineString(coordinates: List.of(drawn));
        await manager.update(annot);
      } catch (_) {
        return annot;
      }

      if (i < allCoords.length) {
        await Future.delayed(Duration(milliseconds: stepMs));
      }
    }

    return annot;
  }

  /// Animate a two-segment route (Driver→Pickup, then Pickup→Dropoff).
  ///
  /// Creates casing (dark outline) + main line for each segment.
  /// Returns all created annotations for later cleanup.
  static Future<List<mapbox.PolylineAnnotation>> animateTwoSegments({
    required mapbox.PolylineAnnotationManager manager,
    required List<LatLng> driverToPickup,
    required List<LatLng> pickupToDropoff,
    int casingColor = 0xFF1A1A2E,
    int segment1Color = 0xFFF5C518,
    int segment2Color = 0xFFF5C518,
    double mainWidth = 8.0,
    double casingWidth = 14.0,
    int stepMs = 6,
    int batchSize = 3,
    int pauseBetweenMs = 180,
    CancellationToken? cancel,
  }) async {
    final result = <mapbox.PolylineAnnotation>[];

    // Segment 1: Driver → Pickup
    if (driverToPickup.length >= 2) {
      // Casing
      final casing1 = await animateSegment(
        manager: manager,
        points: driverToPickup,
        color: casingColor,
        width: casingWidth,
        stepMs: stepMs,
        batchSize: batchSize,
        cancel: cancel,
      );
      if (casing1 != null) result.add(casing1);
      // Main line
      final line1 = await animateSegment(
        manager: manager,
        points: driverToPickup,
        color: segment1Color,
        width: mainWidth,
        stepMs: stepMs,
        batchSize: batchSize,
        cancel: cancel,
      );
      if (line1 != null) result.add(line1);
    }

    // Pause between segments
    if (pauseBetweenMs > 0) {
      await Future.delayed(Duration(milliseconds: pauseBetweenMs));
    }
    if (cancel?.isCancelled ?? false) return result;

    // Segment 2: Pickup → Dropoff
    if (pickupToDropoff.length >= 2) {
      // Casing
      final casing2 = await animateSegment(
        manager: manager,
        points: pickupToDropoff,
        color: casingColor,
        width: casingWidth,
        stepMs: stepMs,
        batchSize: batchSize,
        cancel: cancel,
      );
      if (casing2 != null) result.add(casing2);
      // Main line
      final line2 = await animateSegment(
        manager: manager,
        points: pickupToDropoff,
        color: segment2Color,
        width: mainWidth,
        stepMs: stepMs,
        batchSize: batchSize,
        cancel: cancel,
      );
      if (line2 != null) result.add(line2);
    }

    return result;
  }

  /// Animate a single-segment route with casing.
  static Future<List<mapbox.PolylineAnnotation>> animateWithCasing({
    required mapbox.PolylineAnnotationManager manager,
    required List<LatLng> points,
    int casingColor = 0xFF1A1A2E,
    int lineColor = 0xFFF5C518,
    double mainWidth = 8.0,
    double casingWidth = 14.0,
    int stepMs = 6,
    int batchSize = 3,
    CancellationToken? cancel,
  }) async {
    final result = <mapbox.PolylineAnnotation>[];
    if (points.length < 2) return result;

    // Casing
    final casing = await animateSegment(
      manager: manager,
      points: points,
      color: casingColor,
      width: casingWidth,
      stepMs: stepMs,
      batchSize: batchSize,
      cancel: cancel,
    );
    if (casing != null) result.add(casing);

    // Main line on top
    final line = await animateSegment(
      manager: manager,
      points: points,
      color: lineColor,
      width: mainWidth,
      stepMs: stepMs,
      batchSize: batchSize,
      cancel: cancel,
    );
    if (line != null) result.add(line);

    return result;
  }

  /// Animate camera to fit bounds that contain all given points.
  static Future<void> fitBounds({
    required mapbox.MapboxMap map,
    required List<LatLng> points,
    double padding = 60.0,
    int durationMs = 1000,
  }) async {
    if (points.isEmpty) return;
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    await map.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(
          coordinates: mapbox.Position(
            (minLng + maxLng) / 2,
            (minLat + maxLat) / 2,
          ),
        ),
        zoom: _estimateZoom(minLat, maxLat, minLng, maxLng),
        pitch: 0,
        bearing: 0,
      ),
      mapbox.MapAnimationOptions(duration: durationMs),
    );
  }

  static double _estimateZoom(
    double minLat, double maxLat, double minLng, double maxLng,
  ) {
    final latSpan = (maxLat - minLat).abs();
    final lngSpan = (maxLng - minLng).abs();
    final span = latSpan > lngSpan ? latSpan : lngSpan;
    if (span < 0.002) return 16.5;
    if (span < 0.005) return 15.5;
    if (span < 0.01) return 14.5;
    if (span < 0.02) return 13.5;
    if (span < 0.05) return 12.5;
    if (span < 0.1) return 11.5;
    if (span < 0.3) return 10.0;
    return 9.0;
  }
}

/// Simple cancellation token for async route animation.
class CancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}
