import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import '../models/lat_lng.dart';

/// Where a coordinate lands on screen, computed here instead of asked of the
/// map.
///
/// The driver's marker is drawn by Flutter rather than handed to Mapbox as an
/// annotation, because an annotation can only move as fast as the platform
/// channel drains and that is what makes it step. While the camera follows
/// the driver that is easy — the marker never leaves the centre of the
/// viewport. The moment the driver drags or zooms the map, it does not: the
/// marker has to sit at whatever pixel their real position falls on.
///
/// Asking the map for that pixel every frame would put us straight back on
/// the channel we are trying to get off. But we do not have to ask. A
/// dragged camera is a *still* camera — only the driver is moving — and
/// Mapbox tells us the camera state on every change through
/// `onCameraChangeListener`. Given centre, zoom and viewport, the pixel is
/// arithmetic: Web Mercator, the same projection the map itself uses.
///
/// **Flat cameras only.** [screenOffsetFlat] returns null unless pitch and
/// bearing are both zero. A tilted camera needs the perspective divide out of
/// Mapbox's own projection matrix, and a marker drawn at a *confidently
/// wrong* pixel is worse than one that steps — so the tilted navigation view
/// keeps using the annotation. The flat case is the home mini-map and the
/// online searching map, which is where a driver actually pans and zooms.
class FlatMapProjection {
  const FlatMapProjection._();

  /// Mapbox's tile size. World width in pixels is this times 2^zoom.
  static const double tileSize = 512.0;

  /// Screen position of [target], or null if this camera is not flat.
  ///
  /// The result may fall outside [viewport] — that is meaningful, not an
  /// error: it says the driver is off screen, which is exactly what a driver
  /// who panned away should be able to discover by panning back.
  static Offset? screenOffsetFlat({
    required LatLng target,
    required LatLng cameraCenter,
    required double zoom,
    required double bearingDeg,
    required double pitchDeg,
    required Size viewport,
  }) {
    if (bearingDeg.abs() > 0.01 || pitchDeg.abs() > 0.01) return null;
    if (!zoom.isFinite || zoom < 0 || zoom > 24) return null;
    if (!viewport.width.isFinite || viewport.width <= 0) return null;

    final worldSize = tileSize * math.pow(2.0, zoom).toDouble();
    if (!worldSize.isFinite) return null;

    double x(double lng) => (lng + 180.0) / 360.0 * worldSize;
    double y(double lat) {
      final clamped = lat.clamp(-85.05112878, 85.05112878);
      final s = math.sin(clamped * math.pi / 180.0);
      return (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * worldSize;
    }

    var dx = x(target.longitude) - x(cameraCenter.longitude);
    // Shortest way round the globe, so a driver either side of the
    // antimeridian is not placed a whole world away.
    if (dx > worldSize / 2) {
      dx -= worldSize;
    } else if (dx < -worldSize / 2) {
      dx += worldSize;
    }
    final dy = y(target.latitude) - y(cameraCenter.latitude);
    if (!dx.isFinite || !dy.isFinite) return null;

    return Offset(viewport.width / 2 + dx, viewport.height / 2 + dy);
  }

  /// The flat, north-up camera that puts every one of [points] inside the
  /// part of [viewport] left clear by the insets — the offer route above
  /// the offer card (owner report 2026-11-02, "no se ve la ruta completa").
  ///
  /// Worked out here rather than by `cameraForCoordinatesPadding`: on the
  /// phone that fit left the route running down under the card, and how
  /// the native call combines its insets with the padding the map already
  /// carries is not something this code can see or test. This is the map's
  /// own Web Mercator, pinned by tests, and the returned camera is meant to
  /// be applied with ZERO map padding.
  ///
  /// Null when the clear window has no room or a point is not finite.
  static ({LatLng center, double zoom})? fitFlat({
    required List<LatLng> points,
    required Size viewport,
    double top = 0,
    double left = 0,
    double bottom = 0,
    double right = 0,
    double maxZoom = 22,
  }) {
    if (points.isEmpty) return null;
    final w = viewport.width - left - right;
    final h = viewport.height - top - bottom;
    if (!w.isFinite || !h.isFinite || w <= 0 || h <= 0) return null;

    // Normalised Mercator, 0..1 across the world (multiply by worldSize).
    double u(double lng) => (lng + 180.0) / 360.0;
    double v(double lat) {
      final clamped = lat.clamp(-85.05112878, 85.05112878);
      final s = math.sin(clamped * math.pi / 180.0);
      return 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi);
    }

    var minU = double.infinity, maxU = -double.infinity;
    var minV = double.infinity, maxV = -double.infinity;
    for (final p in points) {
      if (!p.latitude.isFinite || !p.longitude.isFinite) return null;
      final pu = u(p.longitude), pv = v(p.latitude);
      minU = math.min(minU, pu);
      maxU = math.max(maxU, pu);
      minV = math.min(minV, pv);
      maxV = math.max(maxV, pv);
    }

    final du = (maxU - minU) * tileSize;
    final dv = (maxV - minV) * tileSize;
    var zoom = maxZoom;
    if (du > 0 || dv > 0) {
      final scale = math.min(
        du > 0 ? w / du : double.infinity,
        dv > 0 ? h / dv : double.infinity,
      );
      zoom = math.log(scale) / math.ln2;
    }
    if (!zoom.isFinite) return null;
    zoom = zoom.clamp(0.0, maxZoom).toDouble();

    // The camera centre is what lands mid-viewport; the box's centre has to
    // land mid-WINDOW instead, so shift by the gap between the two.
    final worldSize = tileSize * math.pow(2.0, zoom).toDouble();
    final shiftX = (left + w / 2) - viewport.width / 2;
    final shiftY = (top + h / 2) - viewport.height / 2;
    final cu = (minU + maxU) / 2 - shiftX / worldSize;
    final cv = (minV + maxV) / 2 - shiftY / worldSize;
    final lat = math.atan(_sinh(math.pi * (1 - 2 * cv))) * 180.0 / math.pi;
    final lng = cu * 360.0 - 180.0;
    if (!lat.isFinite || !lng.isFinite) return null;
    return (center: LatLng(lat, lng), zoom: zoom);
  }

  static double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2;

  /// Whether [offset] is close enough to the viewport to be worth drawing.
  ///
  /// [margin] keeps a marker that is only half off the edge visible instead
  /// of popping out, which reads as the dot vanishing rather than leaving.
  static bool isOnScreen(Offset offset, Size viewport, {double margin = 80}) {
    return offset.dx >= -margin &&
        offset.dy >= -margin &&
        offset.dx <= viewport.width + margin &&
        offset.dy <= viewport.height + margin;
  }

  /// Same flat Web-Mercator arithmetic as [screenOffsetFlat] but for a
  /// camera ROTATED by [bearingDeg] (pitch must still be ~zero).
  ///
  /// Why this exists (2026-10-10, user report "la flecha cambia de tamaño /
  /// tiembla / apunta a otro lado al mover el mapa"): the driver searching
  /// map runs heading-UP, so its bearing is the driver's heading — almost
  /// never zero. The flat-only variant bailed to null on exactly that map,
  /// the overlay then refused to draw, and the native bitmap annotation took
  /// over mid-gesture — a different renderer with a different size, a stale
  /// rotation and a flicker at every swap. With the rotation applied here the
  /// overlay keeps the marker through the gesture on a heading-up map too.
  ///
  /// The math: bearing B rotates the view so the camera's facing direction
  /// points screen-up; a world offset vector is rotated by -B (screen
  /// coords, y down) to land where the rotated map actually draws it.
  static Offset? screenOffsetHeading({
    required LatLng target,
    required LatLng cameraCenter,
    required double zoom,
    required double bearingDeg,
    required double pitchDeg,
    required Size viewport,
  }) {
    if (pitchDeg.abs() > 0.01) return null; // tilt needs Mapbox's matrix
    // Bearing 0 is exactly the flat case — reuse it.
    if (bearingDeg.abs() <= 0.01) {
      return screenOffsetFlat(
        target: target,
        cameraCenter: cameraCenter,
        zoom: zoom,
        bearingDeg: bearingDeg,
        pitchDeg: pitchDeg,
        viewport: viewport,
      );
    }
    if (!zoom.isFinite || zoom < 0 || zoom > 24) return null;
    if (!viewport.width.isFinite || viewport.width <= 0) return null;

    final worldSize = tileSize * math.pow(2.0, zoom).toDouble();
    if (!worldSize.isFinite) return null;

    double x(double lng) => (lng + 180.0) / 360.0 * worldSize;
    double y(double lat) {
      final clamped = lat.clamp(-85.05112878, 85.05112878);
      final s = math.sin(clamped * math.pi / 180.0);
      return (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * worldSize;
    }

    var dx = x(target.longitude) - x(cameraCenter.longitude);
    if (dx > worldSize / 2) {
      dx -= worldSize;
    } else if (dx < -worldSize / 2) {
      dx += worldSize;
    }
    final dy = y(target.latitude) - y(cameraCenter.latitude);
    if (!dx.isFinite || !dy.isFinite) return null;

    // Rotate the world offset by -bearing (screen coords, y down): at
    // bearing 90° (camera facing east) a point EAST of centre lands
    // screen-UP and a point NORTH lands screen-LEFT.
    final rad = -bearingDeg * math.pi / 180.0;
    final c = math.cos(rad);
    final s = math.sin(rad);
    final rx = dx * c - dy * s;
    final ry = dx * s + dy * c;

    return Offset(viewport.width / 2 + rx, viewport.height / 2 + ry);
  }
}
