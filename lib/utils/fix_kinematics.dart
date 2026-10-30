import 'package:geolocator/geolocator.dart';

/// What the platform actually MEASURED for a fix, as opposed to a default.
///
/// Owner report 2026-10-29 (Android: "la flecha no sigue al driver, no gira,
/// con poca señal ni se mueve"): geolocator_android only writes `speed` /
/// `heading` when `Location.hasSpeed()` / `hasBearing()`; otherwise
/// Position.fromMap fills 0.0. A moving car's network/fused fix therefore
/// read "0 m/s, heading north" — the engine parked the arrow and the heading
/// service fell back to the in-car compass. The accuracy fields are only
/// written when the reading exists, so a 0 with no accuracy is "not
/// measured". iOS already reports -1 for invalid speed/course.

/// Platform speed in m/s, or null when the platform did not measure it.
double? measuredSpeedMps(Position p) {
  final s = p.speed;
  if (!s.isFinite || s < 0) return null;
  if (s == 0 && !(p.speedAccuracy > 0)) return null;
  return s;
}

/// Platform course in degrees [0, 360), or null when not measured.
double? measuredCourseDeg(Position p) {
  final h = p.heading;
  if (!h.isFinite || h < 0) return null;
  if (h == 0 && !(p.headingAccuracy > 0)) return null;
  return h % 360;
}
