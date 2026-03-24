import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

/// Shared map theme helper — dark navy background, gold freeways, grey streets.
///
/// FIX (mapbox_maps_flutter v2 / SDK 11): The native bridge calls
/// Value.fromJson() on property values. A bare hex like '#F5C842' is NOT
/// valid JSON (JSON strings must be double-quoted). We therefore use
/// setStyleLayerProperties(layerId, '{"prop":"value"}') for all string/color
/// properties — this takes an explicit JSON object string and always works.
/// Numeric values (opacity) are passed via setStyleLayerProperty as before
/// because numbers ARE valid JSON without quotes.
class MapTheme {
  MapTheme._();

  // ── Colours ────────────────────────────────────────────────────────────
  static const String _navy       = '#0A1128';  // deep navy background
  static const String _navyLight  = '#0F1A36';  // slightly lighter for land
  static const String _navyWater  = '#070E22';  // darker for water
  static const String _gold       = '#F5C842';  // vivid gold — freeways / highways
  static const String _goldCase   = '#C8960A';  // casing for freeway edges
  static const String _greyRoad   = '#2A2E3A';  // dark grey — primary/secondary streets
  static const String _greyMinor  = '#1E2128';  // darker grey — minor/local streets
  static const String _greyCase   = '#161820';  // casing for grey roads

  // ── Internal helpers ───────────────────────────────────────────────────

  /// Sets a STRING/COLOR layer property using a proper JSON object string.
  /// This avoids the silent failure caused by bare strings not being valid JSON
  /// when the native Mapbox SDK 11 bridge calls Value.fromJson(value).
  static Future<void> _sp(
    mapbox.MapboxMap m,
    String layerId,
    String property,
    String value,
  ) async {
    try {
      await m.style.setStyleLayerProperties(layerId, '{"$property":"$value"}');
    } catch (_) {}
  }

  /// Sets a NUMERIC layer property via setStyleLayerProperty.
  /// Numbers are valid JSON without quoting so the native bridge handles them.
  static Future<void> _np(
    mapbox.MapboxMap m,
    String layerId,
    String property,
    double value,
  ) async {
    try {
      await m.style.setStyleLayerProperty(layerId, property, value);
    } catch (_) {}
  }

  // ── Public API ─────────────────────────────────────────────────────────

  static Future<void> applyNavyGold(mapbox.MapboxMap ctrl) async {
    // ── Hide map ornaments ──────────────────────────────────────────────
    try { ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false)); } catch (_) {}
    try { ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false)); } catch (_) {}
    try { ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false)); } catch (_) {}
    try { ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false)); } catch (_) {}

    // ── Background / land / water → dark navy ───────────────────────────
    for (final layer in ['background', 'land']) {
      await _sp(ctrl, layer, 'background-color', _navy);
    }
    for (final layer in ['landcover', 'landuse']) {
      await _sp(ctrl, layer, 'fill-color', _navyLight);
    }
    for (final layer in ['water', 'water-shadow']) {
      await _sp(ctrl, layer, 'fill-color', _navyWater);
    }

    // ── FREEWAYS / HIGHWAYS → gold ──────────────────────────────────────
    // Covers v10 (legacy navigation), v11 (dark-v11), and combined layers
    const goldRoads = [
      // v10 legacy navigation style layers
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
      // v11 dark-v11 — combined motorway+trunk layers
      'road-motorway-trunk',
      'bridge-motorway-trunk',
      'tunnel-motorway-trunk',
      'road-motorway-trunk-link',
      'bridge-motorway-trunk-link',
      'tunnel-motorway-trunk-link',
      // v11 alternative naming
      'road-major',
      'road-highway',
      'road-motorway-alt',
      'motorway',
      'trunk',
      'highway',
      'road-motorway-2',
      'road-trunk-2',
      'road-motorway-alt-1',
      'road-motorway-alt-2',
      'road-highway-motorway',
      'road-highway-trunk',
      'road-motorway-primary',
      'road-trunk-primary',
      'bridge-motorway-primary',
      'bridge-trunk-primary',
      'tunnel-motorway-primary',
      'tunnel-trunk-primary',
    ];
    for (final layer in goldRoads) {
      await _sp(ctrl, layer, 'line-color', _gold);
    }

    // ── Freeway casings → darker gold ───────────────────────────────────
    const goldCasings = [
      'road-motorway-case',
      'road-trunk-case',
      'bridge-motorway-case',
      'bridge-trunk-case',
      'tunnel-motorway-case',
      'tunnel-trunk-case',
      'road-highway-case',
      'road-major-case',
      'motorway-case',
      'trunk-case',
      'highway-case',
      'road-motorway-trunk-case',
      'bridge-motorway-trunk-case',
      'tunnel-motorway-trunk-case',
      'road-motorway-alt-case',
      'road-highway-motorway-case',
      'road-highway-trunk-case',
      'bridge-motorway-alt-case',
      'bridge-highway-case',
      'tunnel-motorway-alt-case',
      'tunnel-highway-case',
    ];
    for (final layer in goldCasings) {
      await _sp(ctrl, layer, 'line-color', _goldCase);
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
      'road-primary-navigation-1',
      'road-primary-navigation-2',
      'bridge-primary-1',
      'bridge-primary-2',
      'tunnel-primary-1',
      'tunnel-primary-2',
    ];
    for (final layer in greyRoads) {
      await _sp(ctrl, layer, 'line-color', _greyRoad);
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
      'road-street-navigation-1',
      'road-street-navigation-2',
      'road-minor-navigation',
      'road-minor-navigation-1',
    ];
    for (final layer in greyMinorRoads) {
      await _sp(ctrl, layer, 'line-color', _greyMinor);
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
      'road-primary-case-1',
      'road-primary-case-2',
      'road-secondary-tertiary-case-1',
    ];
    for (final layer in greyCasings) {
      await _sp(ctrl, layer, 'line-color', _greyCase);
    }

    // ── Road labels → gold for freeways, muted grey for others ─────────
    await _sp(ctrl, 'road-label', 'text-color', '#5A6070');
    await _sp(ctrl, 'road-number-shield', 'text-color', _gold);
    await _sp(ctrl, 'road-exit-shield', 'text-color', _gold);
    await _sp(ctrl, 'road-label-navigation', 'text-color', '#5A6070');
    await _sp(ctrl, 'road-label-simple', 'text-color', '#5A6070');

    // ── Buildings → dark navy tint ──────────────────────────────────────
    for (final layer in ['building', 'building-outline']) {
      await _sp(ctrl, layer, 'fill-color', '#111D3A');
    }

    // ── Traffic layers → COMPLETELY HIDDEN ─────────────────────────────
    const trafficLayers = [
      'traffic', 'traffic-slow', 'traffic-case',
      'traffic-moderate', 'traffic-heavy', 'traffic-severe',
      'traffic-v1', 'traffic-v1-case',
    ];
    for (final layer in trafficLayers) {
      await _np(ctrl, layer, 'line-opacity', 0.0);
      await _sp(ctrl, layer, 'visibility', 'none');
    }

    // ── Dynamic fallback: enumerate ALL layers, gold any motorway/trunk/highway ──
    // This catches any layer names not in the hardcoded lists above.
    try {
      final layers = await ctrl.style.getStyleLayers();
      final motorwayPattern = RegExp(r'(motorway|trunk|highway)', caseSensitive: false);
      for (final layer in layers) {
        if (layer == null) continue;
        final id = layer.id;
        if (!motorwayPattern.hasMatch(id)) continue;
        if (id.contains('label') || id.contains('shield')) continue;
        if (id.contains('case')) {
          await _sp(ctrl, id, 'line-color', _goldCase);
        } else {
          await _sp(ctrl, id, 'line-color', _gold);
        }
      }
    } catch (_) {}

    // ── Apply golden roads + POI visibility ────────────────────────────
    await applyGoldenRoads(ctrl);
    await applyPoiVisibility(ctrl);
  }

  // ════════════════════════════════════════════════════════════════════════
  // Golden Roads — #F5C842 on FREEWAYS / HIGHWAYS only
  // ════════════════════════════════════════════════════════════════════════
  static Future<void> applyGoldenRoads(mapbox.MapboxMap map) async {
    const color = _gold;
    const casingColor = _goldCase;

    // Motorway / trunk fill layers
    const fillLayers = [
      'road-motorway-trunk',
      'road-motorway',
      'road-trunk',
      'road-motorway-trunk-link',
      'bridge-motorway-trunk',
      'bridge-motorway-trunk-link',
      'tunnel-motorway-trunk',
      'tunnel-motorway-trunk-link',
      'motorway',
      'motorway_link',
      'trunk',
      'trunk_link',
    ];
    for (final layerId in fillLayers) {
      await _sp(map, layerId, 'line-color', color);
    }

    // Motorway / trunk casing layers
    const caseLayers = [
      'road-motorway-trunk-case',
      'road-motorway-case',
      'road-trunk-case',
      'bridge-motorway-trunk-case',
      'bridge-motorway-case',
      'bridge-trunk-case',
      'tunnel-motorway-trunk-case',
      'tunnel-motorway-case',
      'tunnel-trunk-case',
      'motorway-case',
      'trunk-case',
    ];
    for (final layerId in caseLayers) {
      await _sp(map, layerId, 'line-color', casingColor);
    }

    // Dynamic fallback: enumerate all layers for any motorway/trunk/highway missed above
    try {
      final allLayers = await map.style.getStyleLayers();
      final fwPattern = RegExp(r'(motorway|trunk|highway)', caseSensitive: false);
      for (final layer in allLayers) {
        if (layer == null) continue;
        final id = layer.id;
        if (!fwPattern.hasMatch(id)) continue;
        if (id.contains('label') || id.contains('shield') || id.contains('number')) continue;
        if (id.contains('case')) {
          await _sp(map, id, 'line-color', casingColor);
        } else {
          await _sp(map, id, 'line-color', color);
        }
      }
    } catch (_) {}
  }

  // ════════════════════════════════════════════════════════════════════════
  // POI / Business Icons — make visible on all maps
  // ════════════════════════════════════════════════════════════════════════
  static Future<void> applyPoiVisibility(mapbox.MapboxMap map) async {
    const layers = [
      'poi-label', 'poi', 'place-of-worship',
      'poi-scalerank1', 'poi-scalerank2', 'poi-scalerank3', 'poi-scalerank4',
      'points-of-interest', 'landmark-icon',
    ];
    for (final layerId in layers) {
      await _sp(map, layerId, 'visibility', 'visible');
      await _np(map, layerId, 'icon-opacity', 1.0);
      await _np(map, layerId, 'text-opacity', 1.0);
    }

    // Dynamic fallback
    try {
      final allLayers = await map.style.getStyleLayers();
      final poiPattern = RegExp(r'(poi|point.?of.?interest|landmark)', caseSensitive: false);
      for (final layer in allLayers) {
        if (layer == null) continue;
        final id = layer.id;
        if (!poiPattern.hasMatch(id)) continue;
        await _sp(map, id, 'visibility', 'visible');
        await _np(map, id, 'icon-opacity', 1.0);
        await _np(map, id, 'text-opacity', 1.0);
      }
    } catch (_) {}
  }

  /// Alias matching the user-facing name.
  static Future<void> enablePOILayers(mapbox.MapboxMap map) => applyPoiVisibility(map);
}
