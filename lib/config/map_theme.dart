import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

/// Shared map theme helper — dark navy background, gold freeways, grey streets.
class MapTheme {
  MapTheme._();

  // ── Colours ────────────────────────────────────────────────────────────
  static const String _navy       = '#0A1128';  // deep navy background
  static const String _navyLight  = '#0F1A36';  // slightly lighter for land
  static const String _navyWater  = '#070E22';  // darker for water
  static const String _gold       = '#D4A843';  // gold — freeways / highways only
  static const String _goldCase   = '#8B6F2E';  // casing for freeway edges
  static const String _greyRoad   = '#2A2E3A';  // dark grey — primary/secondary streets
  static const String _greyMinor  = '#1E2128';  // darker grey — minor/local streets
  static const String _greyCase   = '#161820';  // casing for grey roads

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

    // ── FREEWAYS / HIGHWAYS → gold ──────────────────────────────────────
    const goldRoads = [
      'road-motorway',
      'road-motorway-navigation',
      'road-trunk',
      'road-trunk-navigation',
      'road-motorway-trunk-link',
      'bridge-motorway',
      'bridge-trunk',
      'bridge-motorway-trunk-link',
      'tunnel-motorway',
      'tunnel-trunk',
      'tunnel-motorway-trunk-link',
    ];
    for (final layer in goldRoads) {
      try { await ctrl.style.setStyleLayerProperty(layer, 'line-color', _gold); } catch (_) {}
    }

    // ── Freeway casings → darker gold ───────────────────────────────────
    const goldCasings = [
      'road-motorway-case',
      'road-trunk-case',
      'bridge-motorway-case',
      'bridge-trunk-case',
      'tunnel-motorway-case',
      'tunnel-trunk-case',
    ];
    for (final layer in goldCasings) {
      try { await ctrl.style.setStyleLayerProperty(layer, 'line-color', _goldCase); } catch (_) {}
    }

    // ── Primary / secondary streets → dark grey ─────────────────────────
    const greyRoads = [
      'road-primary',
      'road-primary-navigation',
      'road-primary-link',
      'road-secondary',
      'road-secondary-tertiary',
      'road-secondary-tertiary-navigation',
      'road-secondary-tertiary-link',
      'bridge-primary',
      'bridge-secondary-tertiary',
      'bridge-primary-link',
      'bridge-secondary-tertiary-link',
      'tunnel-primary',
      'tunnel-secondary-tertiary',
      'tunnel-primary-link',
      'tunnel-secondary-tertiary-link',
    ];
    for (final layer in greyRoads) {
      try { await ctrl.style.setStyleLayerProperty(layer, 'line-color', _greyRoad); } catch (_) {}
    }

    // ── Minor / local / service streets → darker grey ───────────────────
    const greyMinorRoads = [
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
      'bridge-street',
      'bridge-minor',
      'bridge-path-pedestrian',
      'bridge-construction',
      'tunnel-street',
      'tunnel-minor',
      'tunnel-path',
    ];
    for (final layer in greyMinorRoads) {
      try { await ctrl.style.setStyleLayerProperty(layer, 'line-color', _greyMinor); } catch (_) {}
    }

    // ── All road casings (non-freeway) → darkest grey ───────────────────
    const greyCasings = [
      'road-primary-case',
      'road-secondary-tertiary-case',
      'road-street-case',
      'road-minor-case',
      'road-service-link-case',
      'bridge-primary-case',
      'bridge-secondary-tertiary-case',
      'bridge-street-case',
      'bridge-minor-case',
      'tunnel-primary-case',
      'tunnel-secondary-tertiary-case',
      'tunnel-street-case',
      'tunnel-minor-case',
    ];
    for (final layer in greyCasings) {
      try { await ctrl.style.setStyleLayerProperty(layer, 'line-color', _greyCase); } catch (_) {}
    }

    // ── Road labels → gold for freeways, muted grey for others ─────────
    try { await ctrl.style.setStyleLayerProperty('road-label', 'text-color', '#5A6070'); } catch (_) {}
    try { await ctrl.style.setStyleLayerProperty('road-number-shield', 'text-color', _gold); } catch (_) {}
    try { await ctrl.style.setStyleLayerProperty('road-exit-shield', 'text-color', _gold); } catch (_) {}

    // ── Buildings → dark navy tint ──────────────────────────────────────
    for (final layer in ['building', 'building-outline']) {
      try { await ctrl.style.setStyleLayerProperty(layer, 'fill-color', '#111D3A'); } catch (_) {}
    }

    // ── Traffic layers → COMPLETELY HIDDEN ─────────────────────────────
    // Hide all traffic overlays (green/yellow/orange/red lines)
    const trafficLayers = [
      'traffic',
      'traffic-slow',
      'traffic-case',
      'traffic-moderate',
      'traffic-heavy',
      'traffic-severe',
    ];
    for (final layer in trafficLayers) {
      try { await ctrl.style.setStyleLayerProperty(layer, 'line-opacity', 0.0); } catch (_) {}
      try { await ctrl.style.setStyleLayerProperty(layer, 'visibility', 'none'); } catch (_) {}
    }
  }
}
