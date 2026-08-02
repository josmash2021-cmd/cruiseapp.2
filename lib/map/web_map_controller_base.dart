import 'dart:typed_data';

import 'package:flutter/painting.dart' show Offset;

/// LngLat point used by the web map API (records keep call sites readable).
typedef LngLatPoint = ({double lng, double lat});

/// Platform-agnostic contract for the web map controller.
///
/// The real implementation lives in `web_map_view_web.dart` (Mapbox GL JS v3
/// via `dart:js_interop`); `web_map_view_stub.dart` provides a no-op version
/// so native builds (Android/iOS) keep compiling — they never touch
/// `dart:ui_web` / `dart:js_interop`.
abstract class WebMapController {
  /// Fired once the underlying GL map finished its initial load.
  void Function()? onReady;

  /// Fired when the user taps/clicks the map. Arguments: (lng, lat).
  void Function(double lng, double lat)? onMapTap;

  /// Fired on camera movement. Arguments: (zoom, bearing, pitch).
  void Function(double zoom, double bearing, double pitch)? onCameraMove;

  /// Animated camera move.
  void flyTo({
    required double lng,
    required double lat,
    double? zoom,
    double? bearing,
    double? pitch,
    int durationMs = 1500,
  });

  /// Fits the camera so all [points] are visible, with per-edge padding (px).
  void fitBounds(
    List<LngLatPoint> points, {
    double paddingTop = 60,
    double paddingLeft = 60,
    double paddingBottom = 60,
    double paddingRight = 60,
    int durationMs = 1000,
  });

  /// Current zoom level.
  double getZoom();

  /// Current camera center.
  LngLatPoint getCenter();

  /// Switches the base style, e.g. `MapboxConfig.styleDark`
  /// ('mapbox://styles/mapbox/dark-v11'). Overlays (markers, polylines,
  /// circles) must be re-added after a style switch; the implementation
  /// keeps track and restores them automatically.
  void setStyle(String styleUri);

  // ── Markers ──────────────────────────────────────────────────────────────

  /// Adds (or replaces) a marker. [iconBytes] (PNG) or [iconUrl] (incl. data
  /// URLs) render as a custom element; without either, the default Mapbox
  /// pin is used. [rotation] is degrees, aligned to the map.
  void addMarker(
    String id,
    double lng,
    double lat, {
    Uint8List? iconBytes,
    String? iconUrl,
    double rotation = 0,
  });

  void updateMarkerPosition(String id, double lng, double lat,
      {double? rotation});

  void removeMarker(String id);

  void clearMarkers();

  // ── Polylines ────────────────────────────────────────────────────────────

  /// Adds (or replaces) a GeoJSON line. [coordsLngLat] is (lng, lat) order.
  void setPolyline(
    String id,
    List<LngLatPoint> coordsLngLat, {
    String color = '#D4AF37',
    double width = 4,
  });

  void removePolyline(String id);

  void clearPolylines();

  /// Whether a GeoJSON source with this id is currently in the style.
  /// Diagnostic: a layer that was "added" but never renders is told apart
  /// from one that was never added by this one call.
  bool hasSource(String id);

  // ── Circles ──────────────────────────────────────────────────────────────

  /// Adds (or replaces) a screen-space circle ([radiusPx] in pixels).
  void setCircle(
    String id,
    double lng,
    double lat, {
    double radiusPx = 60,
    String color = '#D4AF37',
    double opacity = 0.25,
  });

  void removeCircle(String id);

  void clearCircles();

  // ── Theme ────────────────────────────────────────────────────────────────

  /// Applies the Cruise navy/gold theme on top of dark-v11, replicating the
  /// values of `lib/config/map_theme.dart` (keep both in sync).
  void applyNavyGoldTheme();

  /// Projects a coordinate to container pixels.
  Offset pixelForCoordinate(double lng, double lat);

  /// Releases the GL context and listeners.
  void dispose();
}
