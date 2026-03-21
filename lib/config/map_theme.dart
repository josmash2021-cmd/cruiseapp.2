import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

/// Shared map theme — dark navy blue background, gold freeways,
/// blue normal roads, and traffic: only orange (heavy) + red (severe).
/// Call this in every `onMapCreated` callback.
class MapTheme {
  MapTheme._();

  static const _gold     = '#E8C547';
  static const _goldDim  = '#B8960A';
  static const _navy     = '#0D1B2A';
  static const _navyMid  = '#0A1520';

  static Future<void> applyNavyGold(mapbox.MapboxMap ctrl) async {
    final roadLayers = <String, String>{
      // ── Freeways / motorways → gold ──
      'road-motorway-trunk':      _gold,
      'road-motorway-trunk-case': _goldDim,
      'road-motorway':            _gold,
      'road-motorway-case':       _goldDim,
      'road-trunk':               _gold,
      'road-trunk-case':          _goldDim,
      // ── Primary → blue ──
      'road-primary':             '#1B5DB8',
      'road-primary-case':        '#154A99',
      // ── Secondary / tertiary → darker blue ──
      'road-secondary-tertiary':       '#154A99',
      'road-secondary-tertiary-case':  '#0F3A78',
      // ── Street level → navy blue ──
      'road-street':      '#0F3A78',
      'road-street-case': '#0A2B5C',
      'road-minor':       '#0A2B5C',
      'road-minor-case':  '#071E42',
    };

    for (final entry in roadLayers.entries) {
      try {
        await ctrl.style.setStyleLayerProperty(entry.key, 'line-color', entry.value);
      } catch (_) {}
    }

    try { await ctrl.style.setStyleLayerProperty('land',       'background-color', _navy); }    catch (_) {}
    try { await ctrl.style.setStyleLayerProperty('background', 'background-color', _navyMid); } catch (_) {}
    try { await ctrl.style.setStyleLayerProperty('water',      'fill-color',       '#0A1E35'); } catch (_) {}
    try { await ctrl.style.setStyleLayerProperty('road-label', 'text-color',       _gold); }    catch (_) {}

    // ── Traffic: hide green/yellow, show only orange (heavy) + red (severe) ──
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
