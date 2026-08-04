// @dart=3.6
// pubspec.yaml fija el SDK mínimo en 3.0; este archivo necesita extension
// types y dart:js_interop modernos, así que eleva su language version
// sin tocar pubspec. NO usar dart:html / dart:js_util (rompen nativo).
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/mapbox_config.dart';
import 'web_map_controller_base.dart';

// ════════════════════════════════════════════════════════════════════════════
// Minimal typed bindings for Mapbox GL JS v3 (loaded from CDN in index.html)
// plus the few DOM/JS globals we touch. Only used members are declared.
// ════════════════════════════════════════════════════════════════════════════

@JS('mapboxgl')
extension type _Mapboxgl._(JSObject _) implements JSObject {
  external set accessToken(String token);
}

@JS('mapboxgl')
external _Mapboxgl get _mapboxgl;

/// Presence probe: returns null (undefined) when the CDN script failed.
@JS('mapboxgl')
external JSAny? get _mapboxglPresence;

@JS('mapboxgl.Map')
extension type _JSMap._(JSObject _) implements JSObject {
  external _JSMap(JSObject options);
  external void on(String type, JSFunction listener);
  external void flyTo(JSObject options);
  external void fitBounds(JSAny bounds, JSObject options);
  external void jumpTo(JSObject options);
  external double getZoom();
  external _JSLngLat getCenter();
  external double getBearing();
  external double getPitch();
  external void setStyle(String styleUri);
  external _JSSource? getSource(String id);
  external void addSource(String id, JSObject source);
  external JSAny? getLayer(String id);
  external void addLayer(JSObject layer, [JSAny? beforeId]);
  external void removeLayer(String id);
  external void removeSource(String id);
  external JSArray? queryRenderedFeatures(JSAny pointOrBox, JSAny? options);
  external void setPaintProperty(String layerId, String name, JSAny value);
  external void setLayoutProperty(String layerId, String name, JSAny value);
  external _JSScreenPoint project(JSAny lngLat);
  external void resize();
  external void remove();
}

/// Options bag for `new mapboxgl.Map(...)`; created empty and filled via
/// the setters (compiles to plain property assignment).
extension type _JSMapOptions._(JSObject _) implements JSObject {
  external set container(JSObject element);
  // JSAny, not String: GL JS accepts either a style URL or an inline style
  // object here, and the keyless fallback passes the object.
  external set style(JSAny style);
  external set center(JSAny lngLat);
  external set zoom(double zoom);
  external set pitch(double pitch);
  external set bearing(double bearing);
  external set attributionControl(bool enabled);
}

@JS('mapboxgl.Marker')
extension type _JSMarker._(JSObject _) implements JSObject {
  external _JSMarker([JSObject options]);
  external _JSMarker setLngLat(JSAny lngLat);
  external _JSMarker addTo(_JSMap map);
  external void remove();
  external JSObject? getElement();
}

extension type _JSMarkerOptions._(JSObject _) implements JSObject {
  external set element(JSObject element);
  external set rotation(double degrees);
  external set rotationAlignment(String alignment);
  external set anchor(String anchor);
}

extension type _JSSource._(JSObject _) implements JSObject {
  external void setData(JSAny data);
}

extension type _JSScreenPoint._(JSObject _) implements JSObject {
  external double get x;
  external double get y;
}

extension type _JSLngLat._(JSObject _) implements JSObject {
  external double get lng;
  external double get lat;
}

extension type _JSMapMouseEvent._(JSObject _) implements JSObject {
  external _JSLngLat? get lngLat;
}

extension type _JSMapMoveEvent._(JSObject _) implements JSObject {
  /// Present only when a real input event (mouse/touch/wheel) drove the
  /// move; programmatic flights and resize-triggered moves carry none.
  external JSAny? get originalEvent;
}

@JS('JSON')
extension type _JSJson._(JSObject _) implements JSObject {
  external JSAny parse(String text);
}

@JS('JSON')
external _JSJson get _json;

extension type _JSStyleDeclaration._(JSObject _) implements JSObject {
  external set width(String value);
  external set height(String value);
  external set display(String value);
  external set transition(String value);
  external set transform(String value);
  external set transformOrigin(String value);
}

extension type _JSElement._(JSObject _) implements JSObject {
  external _JSStyleDeclaration get style;
  external set src(String value); // only meaningful for <img>
  external set textContent(String value); // only meaningful for <style>
  external void appendChild(JSObject child);
}

/// Watches an element's box and reports every change.
///
/// GL JS measures its container once, in the Map constructor. Flutter creates
/// that container and hands it to the platform-view registry, which attaches
/// and sizes it afterwards — so the measurement happens against a box that has
/// no size yet, and nothing ever tells the map otherwise. The canvas keeps the
/// size it guessed, which is how a full-screen map ends up drawn into one
/// corner of its own view.
@JS('ResizeObserver')
extension type _JSResizeObserver._(JSObject _) implements JSObject {
  external _JSResizeObserver(JSFunction callback);
  external void observe(JSObject target);
  external void disconnect();
}

@JS('document')
extension type _JSDocument._(JSObject _) implements JSObject {
  external _JSElement createElement(String tag);
  external _JSElement? get head;
}

@JS('document')
external _JSDocument get _document;

// ════════════════════════════════════════════════════════════════════════════
// Theme — values mirror lib/config/map_theme.dart (KEEP IN SYNC).
// ════════════════════════════════════════════════════════════════════════════

const _navy = '#0A1128';
const _gold = '#D4AF37';
const _goldCase = '#B8960C';
const _greyRoad = '#2A2E3A';
const _greyMinor = '#1E2128';
const _greyCase = '#161820';
const _park = '#0A1128';
const _water = '#0D1F3F';
const _building = '#1A2B4D';
const _poiText = '#A8B0C4';
const _poiIcon = '#8A94A8';
const _placeLabel = '#C4CCE0';
const _roadLabel = '#5A6070';

const _goldRoads = [
  'road-motorway', 'road-motorway-navigation', 'road-trunk',
  'road-trunk-navigation', 'road-motorway-trunk-link',
  'bridge-motorway', 'bridge-trunk', 'bridge-motorway-trunk-link',
  'tunnel-motorway', 'tunnel-trunk', 'tunnel-motorway-trunk-link',
  'road-motorway-trunk', 'bridge-motorway-trunk', 'tunnel-motorway-trunk',
  'road-major', 'road-highway',
];
const _goldCasings = [
  'road-motorway-case', 'road-trunk-case',
  'bridge-motorway-case', 'bridge-trunk-case',
  'tunnel-motorway-case', 'tunnel-trunk-case',
  'road-highway-case', 'road-major-case',
  'road-motorway-trunk-case', 'bridge-motorway-trunk-case',
  'tunnel-motorway-trunk-case',
];
const _greyRoads = [
  'road-primary', 'road-primary-navigation', 'road-primary-link',
  'road-secondary', 'road-secondary-tertiary',
  'road-secondary-tertiary-navigation', 'road-secondary-tertiary-link',
  'bridge-primary', 'bridge-secondary-tertiary', 'bridge-primary-link',
  'bridge-secondary-tertiary-link',
  'tunnel-primary', 'tunnel-secondary-tertiary', 'tunnel-primary-link',
  'tunnel-secondary-tertiary-link',
];
const _greyMinorRoads = [
  'road-street', 'road-street-navigation', 'road-street-low',
  'road-minor', 'road-minor-low', 'road-service-link',
  'road-service-link-navigation', 'road-path',
  'road-pedestrian', 'road-pedestrian-navigation',
  'bridge-street', 'bridge-minor', 'bridge-path-pedestrian',
  'bridge-construction',
  'tunnel-street', 'tunnel-minor', 'tunnel-path',
];
const _greyCasings = [
  'road-primary-case', 'road-secondary-tertiary-case',
  'road-street-case', 'road-minor-case', 'road-service-link-case',
  'bridge-primary-case', 'bridge-secondary-tertiary-case',
  'bridge-street-case', 'bridge-minor-case',
  'tunnel-primary-case', 'tunnel-secondary-tertiary-case',
  'tunnel-street-case', 'tunnel-minor-case',
];
const _poiLayers = [
  'poi-label', 'poi', 'poi-scalerank1', 'poi-scalerank2',
  'poi-scalerank3', 'poi-scalerank4',
];
const _placeLayers = [
  'place-label', 'place', 'country-label', 'state-label',
  'settlement-label', 'settlement-subdivision-label',
];

// ════════════════════════════════════════════════════════════════════════════
// Controller
// ════════════════════════════════════════════════════════════════════════════

class _MarkerEntry {
  _MarkerEntry({
    required this.lng,
    required this.lat,
    required this.rotation,
    this.iconBytes,
    this.iconUrl,
    this.widthPx = 40,
    this.heightPx = 40,
    this.anchor = 'center',
  });

  late _JSMarker marker;
  double lng;
  double lat;
  double rotation;
  Uint8List? iconBytes;
  String? iconUrl;
  double widthPx;
  double heightPx;
  String anchor;
}

typedef _PolylineSpec = ({List<LngLatPoint> coords, String color, double width});
typedef _CircleSpec = ({
  double lng,
  double lat,
  double radiusPx,
  String color,
  double opacity,
});

/// Mapbox GL JS-backed controller. Only compiled for web.
class WebMapControllerWeb extends WebMapController {
  WebMapControllerWeb(this._map);

  final _JSMap _map;

  bool _styleReady = false;
  bool _navyGoldApplied = false;

  final _markers = <String, _MarkerEntry>{};
  final _polylines = <String, _PolylineSpec>{};
  final _circles = <String, _CircleSpec>{};

  static JSAny _js(Object? json) => _json.parse(jsonEncode(json));

  /// Called by the view once listeners can be attached.
  void attachEvents() {
    _map.on('load', ((JSAny? _) {
      _styleReady = true;
      _restoreOverlays();
      // Re-theme here too: if an early 'styledata' flipped readiness while
      // the style was still half-parsed, the theme's first pass painted a
      // fraction of the layers — this pass runs against the complete style.
      if (_navyGoldApplied) _applyThemeNow();
      onReady?.call();
    }).toJS);

    // Sources/layers vanish on every style switch — restore + re-theme.
    _map.on('style.load', ((JSAny? _) {
      _styleReady = true;
      _restoreOverlays();
      if (_navyGoldApplied) _applyThemeNow();
      if (_poisHidden) _hidePoisNow();
    }).toJS);

    // 'load' waits for every tile in the viewport, and a single hanging
    // tile delays it indefinitely — meanwhile the style itself is already
    // mutable, which is all overlays need. 'styledata' proves that, so it
    // also flips readiness; without it one unlucky tile kept stored
    // polylines undrawn while DOM markers showed up fine.
    _map.on('styledata', ((JSAny? _) {
      if (!_styleReady) {
        _styleReady = true;
        _restoreOverlays();
        if (_navyGoldApplied) _applyThemeNow();
      }
    }).toJS);

    _map.on('click', ((JSAny? event) {
      final cb = onMapTap;
      if (cb == null || event == null) return;
      final lngLat = _JSMapMouseEvent._(event as JSObject).lngLat;
      if (lngLat == null) return;
      cb(lngLat.lng, lngLat.lat);
    }).toJS);

    _map.on('move', ((JSAny? event) {
      onCameraMove?.call(_map.getZoom(), _map.getBearing(), _map.getPitch());
      // originalEvent is the difference between the rider's hand and our
      // own flights/resizes — only the hand reaches onUserGesture.
      if (event != null &&
          _JSMapMoveEvent._(event as JSObject).originalEvent != null) {
        onUserGesture?.call();
      }
    }).toJS);
  }

  // ── Camera ────────────────────────────────────────────────────────────

  @override
  void flyTo({
    required double lng,
    required double lat,
    double? zoom,
    double? bearing,
    double? pitch,
    int durationMs = 1500,
  }) {
    // Guarded: screens keep controller handles past the widget's death
    // (suspend/remount cycles), and GL JS throws on a removed map. A stale
    // camera write must be a no-op, never an uncaught JS exception inside
    // whatever tick issued it.
    try {
      _map.flyTo(_js({
        'center': [lng, lat],
        if (zoom != null) 'zoom': zoom,
        if (bearing != null) 'bearing': bearing,
        if (pitch != null) 'pitch': pitch,
        'duration': durationMs,
        'essential': true,
      }) as JSObject);
    } catch (_) {}
  }

  @override
  void fitBounds(
    List<LngLatPoint> points, {
    double paddingTop = 60,
    double paddingLeft = 60,
    double paddingBottom = 60,
    double paddingRight = 60,
    int durationMs = 1000,
    double? pitch,
    double? bearing,
  }) {
    if (points.isEmpty) return;
    if (points.length == 1) {
      flyTo(
          lng: points.first.lng,
          lat: points.first.lat,
          pitch: pitch,
          bearing: bearing,
          durationMs: durationMs);
      return;
    }
    var minLng = points.first.lng, maxLng = points.first.lng;
    var minLat = points.first.lat, maxLat = points.first.lat;
    for (final p in points) {
      if (p.lng < minLng) minLng = p.lng;
      if (p.lng > maxLng) maxLng = p.lng;
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
    }
    // Same stale-handle guard as flyTo: a write to a removed map is a
    // no-op, not an uncaught JS exception.
    try {
      _map.fitBounds(
        _js([
          [minLng, minLat],
          [maxLng, maxLat],
        ]),
        _js({
          'padding': {
            'top': paddingTop,
            'left': paddingLeft,
            'bottom': paddingBottom,
            'right': paddingRight,
          },
          'duration': durationMs,
          // No maxZoom cap — native cameraForCoordinatesPadding has none,
          // and the 17 ceiling framed short trips wider than Android does.
          // GL JS fitBounds takes full CameraOptions: with these in the bag
          // the fit flies center+zoom+bearing+pitch as ONE animation — the
          // browser twin of the native cinematic's unified controller.
          if (pitch != null) 'pitch': pitch,
          if (bearing != null) 'bearing': bearing,
        }) as JSObject,
      );
    } catch (_) {}
  }

  @override
  double getZoom() => _map.getZoom();

  @override
  LngLatPoint getCenter() {
    final c = _map.getCenter();
    return (lng: c.lng, lat: c.lat);
  }

  @override
  void setStyle(String styleUri) {
    _styleReady = false;
    _map.setStyle(styleUri);
    // Overlays + theme are restored by the 'style.load' listener.
  }

  // ── Markers ───────────────────────────────────────────────────────────

  _JSElement? _iconElement(Uint8List? bytes, String? url,
      {double widthPx = 40, double heightPx = 40}) {
    if (bytes == null && url == null) return null;
    final img = _document.createElement('img');
    img.src = url ?? 'data:image/png;base64,${base64Encode(bytes!)}';
    img.style
      ..width = '${widthPx}px'
      ..height = '${heightPx}px'
      ..display = 'block';
    return img;
  }

  _JSMarker _createJsMarker(_MarkerEntry e) {
    final opts = _JSMarkerOptions._(JSObject());
    final el = _iconElement(e.iconBytes, e.iconUrl,
        widthPx: e.widthPx, heightPx: e.heightPx);
    if (el != null) opts.element = el;
    if (e.anchor != 'center') opts.anchor = e.anchor;
    if (e.rotation != 0) {
      opts.rotation = e.rotation;
      opts.rotationAlignment = 'map';
    }
    return _JSMarker(opts)
        .setLngLat(_js([e.lng, e.lat]))
        .addTo(_map);
  }

  @override
  void addMarker(
    String id,
    double lng,
    double lat, {
    Uint8List? iconBytes,
    String? iconUrl,
    double rotation = 0,
    bool popIn = false,
    double widthPx = 40,
    double heightPx = 40,
    String anchor = 'center',
  }) {
    removeMarker(id);
    final entry = _MarkerEntry(
      lng: lng,
      lat: lat,
      rotation: rotation,
      iconBytes: iconBytes,
      iconUrl: iconUrl,
      widthPx: widthPx,
      heightPx: heightPx,
      anchor: anchor,
    );
    entry.marker = _createJsMarker(entry);
    _markers[id] = entry;
    if (popIn) _popInMarker(entry);
  }

  /// CSS twin of the native pin pop (TweenSequence 0.01 → 1.15 → 0.95 → 1
  /// over 500 ms): the overshooting cubic-bezier lands the same feel in one
  /// transition. The transform animates the icon INSIDE the marker — GL JS
  /// positions the marker itself via its own transform, which must not be
  /// touched.
  void _popInMarker(_MarkerEntry e) {
    final el = e.marker.getElement();
    if (el == null) return;
    try {
      final style = _JSElement._(el).style;
      // Bottom-anchored pins grow from their tip, centered ones from their
      // middle — matches how the native iconSize scale reads on screen.
      style.transformOrigin =
          e.anchor == 'bottom' ? 'center bottom' : 'center';
      style.transform = 'scale(0.01)';
      Timer(const Duration(milliseconds: 30), () {
        try {
          style.transition =
              'transform 500ms cubic-bezier(0.34, 1.56, 0.64, 1)';
          style.transform = 'scale(1)';
        } catch (_) {}
      });
    } catch (_) {}
  }

  @override
  void updateMarkerPosition(String id, double lng, double lat,
      {double? rotation}) {
    final entry = _markers[id];
    if (entry == null) return;
    entry.lng = lng;
    entry.lat = lat;
    if (rotation != null && rotation != entry.rotation) {
      // GL JS markers take rotation only at construction time.
      entry.rotation = rotation;
      entry.marker.remove();
      entry.marker = _createJsMarker(entry);
    } else {
      entry.marker.setLngLat(_js([lng, lat]));
    }
  }

  @override
  void removeMarker(String id) {
    _markers.remove(id)?.marker.remove();
  }

  @override
  void clearMarkers() {
    for (final e in _markers.values) {
      e.marker.remove();
    }
    _markers.clear();
  }

  // ── Polylines ─────────────────────────────────────────────────────────

  @override
  void setPolyline(
    String id,
    List<LngLatPoint> coordsLngLat, {
    String color = '#D4AF37',
    double width = 4,
  }) {
    _polylines[id] = (coords: coordsLngLat, color: color, width: width);
    if (_styleReady) _upsertPolyline(id);
  }

  void _upsertPolyline(String id) {
    final spec = _polylines[id];
    if (spec == null) return;
    final sourceId = 'cruise-polyline-$id';
    // Guarded, with the failure logged: an addLayer throw here used to
    // escape into a JS event callback (restore) or an async frame (the
    // preview's re-assert) and vanish — the line silently never existed.
    try {
      final existing = _map.getSource(sourceId);
      if (existing != null) {
        existing.setData(_js(_feature(spec)));
        // A source can outlive its layer — a style that finished loading
        // after the first add can drop the runtime layer, and this branch
        // used to never put it back: every later upsert took the same
        // branch, so the line existed as data and never as paint.
        if (_map.getLayer(sourceId) == null) {
          _map.addLayer(_lineLayerSpec(sourceId, spec), _lineBeforeId);
        }
        return;
      }
      _map.addSource(
          sourceId,
          _js({'type': 'geojson', 'data': _feature(spec)}) as JSObject);
      _map.addLayer(_lineLayerSpec(sourceId, spec), _lineBeforeId);
    } catch (e) {
      debugPrint('[WebMap] polyline upsert FAILED $sourceId: $e');
    }
  }

  JSObject _lineLayerSpec(String sourceId, _PolylineSpec spec) => _js({
        'id': sourceId,
        'type': 'line',
        'source': sourceId,
        'layout': {'line-cap': 'round', 'line-join': 'round'},
        'paint': {
          'line-color': spec.color,
          'line-width': spec.width,
          // Full opacity — native annotation lines are opaque unless the
          // color itself carries alpha; 0.9 read washed-out on the navy.
          'line-opacity': 1.0,
        },
      }) as JSObject;

  /// Street names must stay readable OVER the route lines, same as native
  /// (its polyline manager is created below 'road-label'). Null when the
  /// style has no such layer — addLayer then stacks on top as before.
  JSAny? get _lineBeforeId =>
      _map.getLayer('road-label') != null ? 'road-label'.toJS : null;

  @override
  bool hasSource(String id) {
    try {
      return _map.getSource(id) != null;
    } catch (_) {
      return false;
    }
  }

  @override
  bool hasLayer(String id) {
    try {
      return _map.getLayer(id) != null;
    } catch (_) {
      return false;
    }
  }

  @override
  int renderedFeatureCount(String layerId, double lng, double lat) {
    try {
      final p = _map.project(_js([lng, lat]));
      const d = 8.0;
      final feats = _map.queryRenderedFeatures(
        _js([
          [p.x - d, p.y - d],
          [p.x + d, p.y + d],
        ]),
        _js({
          'layers': [layerId],
        }),
      );
      return feats?.length ?? 0;
    } catch (_) {
      return -1;
    }
  }

  Object _feature(_PolylineSpec spec) => {
        'type': 'Feature',
        'properties': <String, Object?>{},
        'geometry': {
          'type': 'LineString',
          'coordinates': [for (final p in spec.coords) [p.lng, p.lat]],
        },
      };

  Object _pointFeature(double lng, double lat) => {
        'type': 'Feature',
        'properties': <String, Object?>{},
        'geometry': {
          'type': 'Point',
          'coordinates': [lng, lat],
        },
      };

  @override
  void removePolyline(String id) {
    _polylines.remove(id);
    final sourceId = 'cruise-polyline-$id';
    if (_styleReady && _map.getLayer(sourceId) != null) {
      _map.removeLayer(sourceId);
      _map.removeSource(sourceId);
    }
  }

  @override
  void clearPolylines() {
    for (final id in _polylines.keys.toList()) {
      removePolyline(id);
    }
  }

  // ── Circles ───────────────────────────────────────────────────────────

  @override
  void setCircle(
    String id,
    double lng,
    double lat, {
    double radiusPx = 60,
    String color = '#D4AF37',
    double opacity = 0.25,
  }) {
    _circles[id] = (
      lng: lng,
      lat: lat,
      radiusPx: radiusPx,
      color: color,
      opacity: opacity,
    );
    if (_styleReady) _upsertCircle(id);
  }

  void _upsertCircle(String id) {
    final spec = _circles[id];
    if (spec == null) return;
    final sourceId = 'cruise-circle-$id';
    final existing = _map.getSource(sourceId);
    if (existing != null) {
      existing.setData(_js(_pointFeature(spec.lng, spec.lat)));
      // The layer outlives setData, so radius/opacity must be pushed too —
      // without this a setCircle that only changes the paint (e.g. the
      // picker ripple animating its waves frame by frame) moved nothing.
      if (_map.getLayer(sourceId) != null) {
        try {
          _map.setPaintProperty(sourceId, 'circle-radius', spec.radiusPx.toJS);
          _map.setPaintProperty(sourceId, 'circle-opacity', spec.opacity.toJS);
          _map.setPaintProperty(
              sourceId,
              'circle-stroke-opacity',
              (spec.opacity + 0.3 > 1 ? 1.0 : spec.opacity + 0.3).toJS);
        } catch (_) {}
      }
      return;
    }
    _map.addSource(
        sourceId,
        _js({
          'type': 'geojson',
          'data': _pointFeature(spec.lng, spec.lat),
        }) as JSObject);
    _map.addLayer(_js({
      'id': sourceId,
      'type': 'circle',
      'source': sourceId,
      'paint': {
        'circle-radius': spec.radiusPx,
        'circle-color': spec.color,
        'circle-opacity': spec.opacity,
        'circle-stroke-width': 1.5,
        'circle-stroke-color': spec.color,
        'circle-stroke-opacity':
            spec.opacity + 0.3 > 1 ? 1.0 : spec.opacity + 0.3,
      },
    }) as JSObject);
  }

  @override
  void removeCircle(String id) {
    _circles.remove(id);
    final sourceId = 'cruise-circle-$id';
    if (_styleReady && _map.getLayer(sourceId) != null) {
      _map.removeLayer(sourceId);
      _map.removeSource(sourceId);
    }
  }

  @override
  void clearCircles() {
    for (final id in _circles.keys.toList()) {
      removeCircle(id);
    }
  }

  void _restoreOverlays() {
    for (final id in _polylines.keys) {
      _upsertPolyline(id);
    }
    for (final id in _circles.keys) {
      _upsertCircle(id);
    }
  }

  // ── Theme ─────────────────────────────────────────────────────────────

  @override
  void applyNavyGoldTheme() {
    _navyGoldApplied = true;
    if (_styleReady) _applyThemeNow();
  }

  /// Same list native MapTheme.hidePoiLayers turns off, and applied AFTER
  /// the theme (which switches POIs visible) — the flag makes the order
  /// hold across style reloads too.
  static const _hiddenPoiLayers = [
    'poi-label', 'poi', 'place-of-worship',
    'poi-scalerank1', 'poi-scalerank2', 'poi-scalerank3', 'poi-scalerank4',
    'points-of-interest', 'landmark-icon', 'transit-label',
  ];

  bool _poisHidden = false;

  @override
  void hidePoiLayers() {
    _poisHidden = true;
    if (_styleReady) _hidePoisNow();
  }

  void _hidePoisNow() {
    for (final id in _hiddenPoiLayers) {
      _layout(id, 'visibility', 'none');
    }
  }

  void _paint(String layerId, String name, String value) {
    if (_map.getLayer(layerId) == null) return;
    try {
      _map.setPaintProperty(layerId, name, value.toJS);
    } catch (_) {}
  }

  /// Numeric twin of [_paint] — opacities and bases are JS numbers, not
  /// strings, and GL JS rejects a stringified one.
  void _paintNum(String layerId, String name, double value) {
    if (_map.getLayer(layerId) == null) return;
    try {
      _map.setPaintProperty(layerId, name, value.toJS);
    } catch (_) {}
  }

  void _layout(String layerId, String name, String value) {
    if (_map.getLayer(layerId) == null) return;
    try {
      _map.setLayoutProperty(layerId, name, value.toJS);
    } catch (_) {}
  }

  void _applyThemeNow() {
    for (final id in ['background', 'land']) {
      _paint(id, 'background-color', _navy);
    }
    for (final id in ['landcover', 'landuse']) {
      _paint(id, 'fill-color', _park);
    }
    for (final id in ['water', 'water-shadow']) {
      _paint(id, 'fill-color', _water);
    }
    for (final id in _goldRoads) {
      _paint(id, 'line-color', _gold);
    }
    for (final id in _goldCasings) {
      _paint(id, 'line-color', _goldCase);
    }
    for (final id in _greyRoads) {
      _paint(id, 'line-color', _greyRoad);
    }
    for (final id in _greyMinorRoads) {
      _paint(id, 'line-color', _greyMinor);
    }
    for (final id in _greyCasings) {
      _paint(id, 'line-color', _greyCase);
    }
    for (final id in ['road-label', 'road-label-simple', 'road-label-navigation']) {
      _paint(id, 'text-color', _roadLabel);
    }
    for (final id in ['road-number-shield', 'road-exit-shield']) {
      _paint(id, 'text-color', _gold);
    }
    for (final id in ['building', 'building-outline']) {
      _paint(id, 'fill-color', _building);
    }
    _paint('building', 'fill-extrusion-color', _building);
    _paintNum('building', 'fill-extrusion-opacity', 0.85);
    _paintNum('building', 'fill-extrusion-base', 0);
    for (final id in _poiLayers) {
      // A screen that asked for POIs off keeps them off — the theme's
      // visible-POI pass must not undo hidePoiLayers on a style reload.
      if (!_poisHidden) _layout(id, 'visibility', 'visible');
      _paint(id, 'text-color', _poiText);
      _paint(id, 'icon-color', _poiIcon);
    }
    if (_poisHidden) _hidePoisNow();
    for (final id in _placeLayers) {
      _paint(id, 'text-color', _placeLabel);
    }
    // Traffic layers hidden, same as native (dark-v11 rarely carries them,
    // but a style swap to a traffic variant must not light them up).
    for (final id in [
      'traffic', 'traffic-slow', 'traffic-case',
      'traffic-moderate', 'traffic-heavy', 'traffic-severe',
      'traffic-v1', 'traffic-v1-case',
    ]) {
      _paintNum(id, 'line-opacity', 0);
      _layout(id, 'visibility', 'none');
    }
  }

  // ── Utils ─────────────────────────────────────────────────────────────

  @override
  Offset pixelForCoordinate(double lng, double lat) {
    final p = _map.project(_js([lng, lat]));
    return Offset(p.x, p.y);
  }

  @override
  void dispose() {
    clearMarkers();
    onReady = null;
    onMapTap = null;
    onCameraMove = null;
    try {
      _map.remove();
    } catch (_) {}
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Widget
// ════════════════════════════════════════════════════════════════════════════

/// Embeds a Mapbox GL JS v3 map via [HtmlElementView]. Web only — the
/// conditional import in `web_map_view.dart` swaps in a stub on native.
class WebMapView extends StatefulWidget {
  const WebMapView({
    super.key,
    this.initialLng = -74.006,
    this.initialLat = 40.7128,
    this.initialZoom = 12,
    this.initialPitch = 0,
    this.initialBearing = 0,
    this.styleUri,
    this.onControllerCreated,
  });

  final double initialLng;
  final double initialLat;
  final double initialZoom;

  /// Boot camera tilt/rotation — native screens boot from a handoff camera
  /// (often pitched 45°); without these the browser always opened flat and
  /// north-up regardless of where the previous map left the rider.
  final double initialPitch;
  final double initialBearing;

  /// Base style; defaults to [MapboxConfig.styleDark] (dark-v11).
  final String? styleUri;

  /// Called synchronously with the controller before the first frame.
  final void Function(WebMapController controller)? onControllerCreated;

  @override
  State<WebMapView> createState() => _WebMapViewState();
}

class _WebMapViewState extends State<WebMapView> {
  static int _instanceCounter = 0;

  late final String _viewType;
  WebMapControllerWeb? _controller;
  String? _fatalError;

  @override
  void initState() {
    super.initState();
    _viewType = 'cruise-web-map-${_instanceCounter++}';
    _register();
  }

  /// A dark basemap that needs no Mapbox token.
  ///
  /// The token is a build-time define that only CI holds, so a developer
  /// running `flutter run -d web-server` to review layout has none — and an
  /// empty token used to make the map area a grey apology. Mapbox GL JS can
  /// render a plain raster style from any tile server, so when there is no
  /// token it draws CARTO's dark basemap instead: free, keyless, and close
  /// enough in tone to the app's own dark style that spacing and contrast
  /// can still be judged against it.
  ///
  /// Vector styling, 3D and the navy/gold theme need the real token. This is
  /// for reviewing what sits ON the map, not the map itself.
  static const String _keylessDarkStyle = '''
{"version":8,
 "sources":{"carto-dark":{"type":"raster",
   "tiles":["https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}@2x.png",
            "https://b.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}@2x.png",
            "https://c.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}@2x.png"],
   "tileSize":256,
   "attribution":"© OpenStreetMap contributors © CARTO"}},
 "layers":[{"id":"carto-dark","type":"raster","source":"carto-dark"}]}
''';

  void _register() {
    final token = MapboxConfig.accessToken;
    final keyless = token.isEmpty;
    if (keyless) {
      debugPrint('[WebMapView] no MAPBOX_TOKEN — falling back to a keyless '
          'dark basemap. Vector styling and the navy/gold theme are off.');
    }
    if (_mapboxglPresence == null) {
      _fatalError =
          'mapboxgl no está cargado — revisa el CDN de Mapbox GL JS en web/index.html';
      debugPrint('[WebMapView] $_fatalError');
      return;
    }

    final container = _document.createElement('div');
    container.style
      ..width = '100%'
      ..height = '100%';

    // GL JS insists on a non-empty token even for a raster style it never
    // calls Mapbox for; any string satisfies it.
    _mapboxgl.accessToken = keyless ? 'no-token' : token;

    final options = _JSMapOptions._(JSObject());
    options.container = container;
    options.style = keyless
        ? _json.parse(_keylessDarkStyle)
        : (widget.styleUri ?? MapboxConfig.styleDark).toJS;
    options.center =
        _json.parse(jsonEncode([widget.initialLng, widget.initialLat]));
    options.zoom = widget.initialZoom;
    if (widget.initialPitch != 0) options.pitch = widget.initialPitch;
    if (widget.initialBearing != 0) options.bearing = widget.initialBearing;
    options.attributionControl = false;

    // Mirror the native maps: lib/config/map_theme.dart sets
    // AttributionSettings(enabled: false) AND LogoSettings(enabled: false)
    // on iOS/Android. attributionControl:false above covers the attribution
    // text, but in GL JS the "mapbox" wordmark is a separate control that
    // stays visible — hide it the same way native does. Injected once per
    // page; several WebMapViews share the rule.
    _hideMapboxLogoOnce();

    final map = _JSMap(options);
    final controller = WebMapControllerWeb(map);
    controller.attachEvents();
    _controller = controller;

    // Tell the map its real size, now and whenever it changes.
    //
    // Without this the canvas keeps whatever it measured at construction —
    // before Flutter had attached the container — and the map renders into a
    // fraction of its own view with the rest left black. resize() is cheap and
    // idempotent, so an extra call costs nothing; a missing one costs the map.
    try {
      final ro = _JSResizeObserver(((JSAny? _, JSAny? __) {
        try {
          map.resize();
        } catch (_) {
          // The map can be disposed between the observation and this call.
        }
      }).toJS);
      ro.observe(container);
      _resizeObserver = ro;
    } catch (e) {
      // No ResizeObserver (very old browser): fall back to a few nudges over
      // the first second, which covers the attach that matters.
      debugPrint('[WebMap] ResizeObserver unavailable ($e) — nudging instead');
      for (final ms in const [0, 120, 400, 1000]) {
        Future<void>.delayed(Duration(milliseconds: ms), () {
          try {
            map.resize();
          } catch (_) {}
        });
      }
    }

    final viewType = _viewType;
    ui_web.platformViewRegistry.registerViewFactory(
      viewType,
      (int viewId, {Object? params}) => container,
    );

    widget.onControllerCreated?.call(controller);
  }

  _JSResizeObserver? _resizeObserver;

  static bool _logoCssInjected = false;

  /// Hides the GL JS logo control (`.mapboxgl-ctrl-logo`) page-wide, matching
  /// what the native maps do in `lib/config/map_theme.dart`
  /// (`LogoSettings(enabled: false)`). The attribution control is already off
  /// via `attributionControl: false`, same as native's
  /// `AttributionSettings(enabled: false)` — nothing more is hidden here
  /// than what iOS hides.
  static void _hideMapboxLogoOnce() {
    if (_logoCssInjected) return;
    _logoCssInjected = true;
    try {
      final style = _document.createElement('style');
      style.textContent = '.mapboxgl-ctrl-logo{display:none!important;}';
      _document.head?.appendChild(style);
    } catch (e) {
      debugPrint('[WebMap] could not inject logo-hiding CSS: $e');
    }
  }

  @override
  void dispose() {
    // Before the controller: the observer's callback touches the map, and
    // disposing the map first leaves it firing into a removed object.
    try {
      _resizeObserver?.disconnect();
    } catch (_) {}
    _resizeObserver = null;
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _fatalError;
    if (error != null) {
      return const ColoredBox(
        color: Color(0xFF0A1128),
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Mapa web no disponible.\nRevisa la consola para más detalles.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
          ),
        ),
      );
    }
    return HtmlElementView(viewType: _viewType);
  }
}
