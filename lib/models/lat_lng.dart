/// Platform-agnostic LatLng — replaces google_maps_flutter.LatLng so that
/// services, navigation helpers and models don't depend on any map SDK.
class LatLng {
  final double latitude;
  final double longitude;

  const LatLng(this.latitude, this.longitude);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LatLng &&
          runtimeType == other.runtimeType &&
          latitude == other.latitude &&
          longitude == other.longitude;

  @override
  int get hashCode => latitude.hashCode ^ longitude.hashCode;

  @override
  String toString() => 'LatLng($latitude, $longitude)';
}

/// Axis-aligned bounding box — replaces google_maps_flutter.LatLngBounds.
class LatLngBounds {
  final LatLng southwest;
  final LatLng northeast;

  const LatLngBounds({required this.southwest, required this.northeast});

  bool contains(LatLng point) =>
      point.latitude >= southwest.latitude &&
      point.latitude <= northeast.latitude &&
      point.longitude >= southwest.longitude &&
      point.longitude <= northeast.longitude;
}
