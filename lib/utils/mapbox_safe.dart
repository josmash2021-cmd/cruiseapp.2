// Mapbox-safe coordinate helpers.
//
// Prevents NSInvalidArgumentException - Invalid number value (NaN) in JSON write
// by validating coordinates before passing them to Mapbox annotations.
//
// Usage:
//   final pos = safePosition(lng, lat); // returns null if invalid
//   if (pos == null) return;
//   mgr.create(PointAnnotationOptions(geometry: Point(coordinates: pos), ...));

import 'dart:typed_data';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';

/// Validates a single double coordinate.
bool isValidCoord(double? v) =>
    v != null && v.isFinite && !v.isNaN;

/// Validates lat/lng pair.
bool isValidLatLng(double? lat, double? lng) =>
    isValidCoord(lat) && isValidCoord(lng);

/// Creates a safe Mapbox Position, or null if coordinates are invalid.
mapbox.Position? safePosition(double lng, double lat) {
  if (!isValidLatLng(lat, lng)) return null;
  return mapbox.Position(lng, lat);
}

/// Creates a safe Mapbox Point, or null if coordinates are invalid.
mapbox.Point? safePoint(double lng, double lat) {
  final pos = safePosition(lng, lat);
  if (pos == null) return null;
  return mapbox.Point(coordinates: pos);
}

/// Creates a safe Mapbox Point from LatLng, or null if invalid.
mapbox.Point? safePointFromLatLng(LatLng? ll) {
  if (ll == null) return null;
  return safePoint(ll.longitude, ll.latitude);
}

/// Filters a list of LatLng to only valid coordinates, then creates a LineString.
/// Returns null if fewer than 2 valid points.
mapbox.LineString? safeLineString(Iterable<LatLng> points) {
  final valid = points
      .where((p) => isValidLatLng(p.latitude, p.longitude))
      .map((p) => mapbox.Position(p.longitude, p.latitude))
      .toList();
  if (valid.length < 2) return null;
  return mapbox.LineString(coordinates: valid);
}

/// Filters a list of Position to only valid ones, then creates a LineString.
/// Returns null if fewer than 2 valid points.
mapbox.LineString? safeLineStringFromPositions(Iterable<mapbox.Position> positions) {
  final valid = positions
      .where((p) => isValidLatLng(p.lat.toDouble(), p.lng.toDouble()))
      .toList();
  if (valid.length < 2) return null;
  return mapbox.LineString(coordinates: valid);
}

/// Wraps annotation creation with NaN guard. Returns null if geometry is invalid.
///
/// Example:
///   final annot = await safeCreatePoint(mgr, lng: pos.longitude, lat: pos.latitude, image: bytes);
Future<mapbox.PointAnnotation?> safeCreatePoint(
  mapbox.PointAnnotationManager mgr, {
  required double lng,
  required double lat,
  required Uint8List image,
  double iconSize = 1.0,
  mapbox.IconAnchor iconAnchor = mapbox.IconAnchor.CENTER,
  double? iconRotate,
  List<double>? iconOffset,
}) async {
  final point = safePoint(lng, lat);
  if (point == null) return null;
  try {
    return await mgr.create(mapbox.PointAnnotationOptions(
      geometry: point,
      image: image,
      iconSize: iconSize,
      iconAnchor: iconAnchor,
      iconRotate: iconRotate,
      iconOffset: iconOffset,
    ));
  } catch (_) {
    return null;
  }
}

/// Wraps polyline creation with NaN guard. Returns null if geometry is invalid.
Future<mapbox.PolylineAnnotation?> safeCreatePolyline(
  mapbox.PolylineAnnotationManager mgr, {
  required Iterable<LatLng> points,
  required int lineColor,
  double lineWidth = 5.0,
  mapbox.LineJoin lineJoin = mapbox.LineJoin.ROUND,
}) async {
  final line = safeLineString(points);
  if (line == null) return null;
  try {
    return await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: line,
      lineColor: lineColor,
      lineWidth: lineWidth,
      lineJoin: lineJoin,
    ));
  } catch (_) {
    return null;
  }
}

/// Updates a PointAnnotation geometry safely. Silently skips if invalid.
void safeUpdatePointGeometry(
  mapbox.PointAnnotation annot,
  double lng,
  double lat,
) {
  final point = safePoint(lng, lat);
  if (point == null) return;
  annot.geometry = point;
}

/// Updates a PolylineAnnotation geometry safely. Silently skips if invalid.
void safeUpdatePolylineGeometry(
  mapbox.PolylineAnnotation annot,
  Iterable<LatLng> points,
) {
  final line = safeLineString(points);
  if (line == null) return;
  annot.geometry = line;
}
