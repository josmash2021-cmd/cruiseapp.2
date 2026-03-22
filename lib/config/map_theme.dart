import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

/// Shared map theme helper — dark navy background with gold roads.
class MapTheme {
  MapTheme._();

  // ── Colours ────────────────────────────────────────────────────────────
  static const String _navy      = '#0A1128';   // deep navy background
  static const String _navyLight = '#0F1A36';   // slightly lighter for land
  static const String _navyWater = '#070E22';   // darker for water
  static const String _gold      = '#D4A843';   // gold for roads
  static const String _goldDim   = '#B8923A';   // dimmer gold for smaller roads
  static const String _goldCase  = '#8B6F2E';   // casing / outlines

  static Future<void> applyNavyGold(mapbox.MapboxMap ctrl) async {
    // ── Hide map ornaments ──────────────────────────────────────────────
    try { ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false)); } catch (_) {}
    try { ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false)); } catch (_) {}
    try { ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false)); } catch (_) {}
    try { ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false)); } catch (_) {}

    // ── Background / land / water → dark navy ───────────────────────────
    for (final layer in ['background', 'land']) {
      try { await ctrl.style.setStyleLayerProperty(layer, 'background-color', _navy); } catch (_) {}
    }
    for (final layer in ['landcover', 'landuse']) {
      try { await ctrl.style.setStyleLayerProperty(layer, 'fill-color', _navyLight); } catch (_) {}
    }
    for (final layer in ['water', 'water-shadow']) {
      try { await ctrl.style.setStyleLayerProperty(layer, 'fill-color', _navyWater); } catch (_) {}
    }

    // ── ALL road line layers → gold ─────────────────────────────────────
    // Major roads and highways
    const goldRoads = [
      'road-motorway',
      'road-motorway-navigation',
      'road-trunk',
      'road-trunk-navigation',
      'road-primary',
      'road-primary-navigation',
      'road-secondary',
      'road-secondary-tertiary',
      'road-secondary-tertiary-navigation',
      'road-street',
      'road-street-navigation',
      'road-street-low',
      'road-minor',
      'road-minor-low',
      'road-service-link',
      'road-service-link-navigation',
      'road-path',
      'road-pedestrian',
      'road-pedestrian-navigation',
      // Bridges
      'bridge-motorway',
      'bridge-trunk',
      'bridge-primary',
      'bridge-secondary-tertiary',
      'bridge-street',
      'bridge-minor',
      'bridge-path-pedestrian',
      'bridge-construction',
      // Tunnels
      'tunnel-motorway',
      'tunnel-trunk',
      'tunnel-primary',
      'tunnel-secondary-tertiary',
      'tunnel-street',
      'tunnel-minor',
      'tunnel-path',
      // Links / ramps
      'road-motorway-trunk-link',
      'road-primary-link',
      'road-secondary-tertiary-link',
      'bridge-motorway-trunk-link',
      'bridge-primary-link',
      'bridge-secondary-tertiary-link',
      'tunnel-motorway-trunk-link',
      'tunnel-primary-link',
      'tunnel-secondary-tertiary-link',
      // One-way arrows
      'road-oneway-arrow-blue',
      'road-oneway-arrow-white',
      // Turn lanes
      'turning-feature',
      'turning-feature-outline',
    ];

    for (final layer in goldRoads) {
      try { await ctrl.style.setStyleLayerProperty(layer, 'line-color', _gold); } catch (_) {}
    }

    // ── Road casings → darker gold ──────────────────────────────────────
    const casingRoads = [
      'road-motorway-case',
      'road-trunk-case',
      'road-primary-case',
      'road-secondary-tertiary-case',
      'road-street-case',
      'road-minor-case',
      'road-service-link-case',
      'bridge-motorway-case',
      'bridge-trunk-case',
      'bridge-primary-case',
      'bridge-secondary-tertiary-case',
      'bridge-street-case',
      'bridge-minor-case',
      'tunnel-motorway-case',
      'tunnel-trunk-case',
      'tunnel-primary-case',
      'tunnel-secondary-tertiary-case',
      'tunnel-street-case',
      'tunnel-minor-case',
    ];

    for (final layer in casingRoads) {
      try { await ctrl.style.setStyleLayerProperty(layer, 'line-color', _goldCase); } catch (_) {}
    }

    // ── Smaller roads → dimmer gold ─────────────────────────────────────
    const dimRoads = [
      'road-minor',
      'road-minor-low',
      'road-path',
      'road-pedestrian',
      'road-service-link',
      'bridge-minor',
      'bridge-path-pedestrian',
      'tunnel-minor',
      'tunnel-path',
    ];

    for (final layer in dimRoads) {
      try { await ctrl.style.setStyleLayerProperty(layer, 'line-color', _goldDim); } catch (_) {}
    }

    // ── Road labels → gold text ─────────────────────────────────────────
    const roadLabels = [
      'road-label',
      'road-number-shield',
      'road-exit-shield',
    ];

    for (final layer in roadLabels) {
      try { await ctrl.style.setStyleLayerProperty(layer, 'text-color', _gold); } catch (_) {}
    }

    // ── Buildings → dark navy tint ──────────────────────────────────────
    for (final layer in ['building', 'building-outline']) {
      try { await ctrl.style.setStyleLayerProperty(layer, 'fill-color', '#111D3A'); } catch (_) {}
    }

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
