import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

/// Shared map theme helper.
/// Uses the navigation-night-v1 style as-is (dark navy, gold roads, POI icons).
/// Only hides Mapbox ornaments and filters noisy traffic colours.
class MapTheme {
  MapTheme._();

  static Future<void> applyNavyGold(mapbox.MapboxMap ctrl) async {
    // ── Hide map ornaments ──────────────────────────────────────────────────
    try { ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false)); } catch (_) {}
    try { ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false)); } catch (_) {}
    try { ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false)); } catch (_) {}
    try { ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false)); } catch (_) {}

    // ── Traffic: hide green/yellow, keep only orange (heavy) + red (severe) ─
    for (final layer in ['traffic', 'traffic-slow', 'traffic-case']) {
      try {
        await ctrl.style.setStyleLayerProperty(layer, 'line-opacity', [
          'match',
          ['get', 'congestion'],
          ['low', 'moderate'], 0.0,
          1.0,
        ]);
        await ctrl.style.setStyleLayerProperty(layer, 'line-color', [
          'match',
          ['get', 'congestion'],
          'heavy',  '#FF9500',
          'severe', '#FF3B30',
          'rgba(0,0,0,0)',
        ]);
      } catch (_) {}
    }
  }
}
