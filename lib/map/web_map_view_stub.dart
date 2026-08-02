import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'web_map_controller_base.dart';

/// No-op controller used on native builds, where the web map is unavailable.
/// Method bodies are intentionally empty: screens should only hit this class
/// through `kIsWeb` guards while the native path keeps using
/// `mapbox_maps_flutter`.
class WebMapControllerStub extends WebMapController {
  @override
  void flyTo({
    required double lng,
    required double lat,
    double? zoom,
    double? bearing,
    double? pitch,
    int durationMs = 1500,
  }) {}

  @override
  void fitBounds(
    List<LngLatPoint> points, {
    double paddingTop = 60,
    double paddingLeft = 60,
    double paddingBottom = 60,
    double paddingRight = 60,
    int durationMs = 1000,
  }) {}

  @override
  double getZoom() => 0;

  @override
  LngLatPoint getCenter() => (lng: 0, lat: 0);

  @override
  void setStyle(String styleUri) {}

  @override
  void addMarker(
    String id,
    double lng,
    double lat, {
    Uint8List? iconBytes,
    String? iconUrl,
    double rotation = 0,
  }) {}

  @override
  void updateMarkerPosition(String id, double lng, double lat,
      {double? rotation}) {}

  @override
  void removeMarker(String id) {}

  @override
  void clearMarkers() {}

  @override
  void setPolyline(
    String id,
    List<LngLatPoint> coordsLngLat, {
    String color = '#D4AF37',
    double width = 4,
  }) {}

  @override
  void removePolyline(String id) {}

  @override
  void clearPolylines() {}

  @override
  bool hasSource(String id) => false;

  @override
  bool hasLayer(String id) => false;

  @override
  int renderedFeatureCount(String layerId, double lng, double lat) => 0;

  @override
  void setCircle(
    String id,
    double lng,
    double lat, {
    double radiusPx = 60,
    String color = '#D4AF37',
    double opacity = 0.25,
  }) {}

  @override
  void removeCircle(String id) {}

  @override
  void clearCircles() {}

  @override
  void applyNavyGoldTheme() {}

  @override
  Offset pixelForCoordinate(double lng, double lat) => Offset.zero;

  @override
  void dispose() {}
}

/// Placeholder shown on non-web platforms. The real map lives in
/// `web_map_view_web.dart` and is selected via conditional import.
class WebMapView extends StatelessWidget {
  const WebMapView({
    super.key,
    this.initialLng = -74.006,
    this.initialLat = 40.7128,
    this.initialZoom = 12,
    this.styleUri,
    this.onControllerCreated,
  });

  final double initialLng;
  final double initialLat;
  final double initialZoom;
  final String? styleUri;
  final void Function(WebMapController controller)? onControllerCreated;

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF0A1128),
      child: Center(
        child: Text(
          'WebMapView solo está disponible en web',
          style: TextStyle(color: Colors.white54),
        ),
      ),
    );
  }
}
