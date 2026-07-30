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
}
