// @dart=3.6
// pubspec.yaml fija el SDK mínimo en 3.0; este archivo necesita extension
// types y dart:js_interop modernos, así que eleva su language version
// sin tocar pubspec. NO usar dart:html / dart:js_util (rompen nativo).
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
  external void addLayer(JSObject layer);
  external void removeLayer(String id);
  external void removeSource(String id);
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
  external set attributionControl(bool enabled);
}

@JS('mapboxgl.Marker')
extension type _JSMarker._(JSObject _) implements JSObject {
  external _JSMarker([JSObject options]);
  external _JSMarker setLngLat(JSAny lngLat);
  external _JSMarker addTo(_JSMap map);
  external void remove();
}

extension type _JSMarkerOptions._(JSObject _) implements JSObject {
  external set element(JSObject element);
  external set rotation(double degrees);
  external set rotationAlignment(String alignment);
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
}

extension type _JSElement._(JSObject _) implements JSObject {
  external _JSStyleDeclaration get style;
  external set src(String value); // only meaningful for <img>
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
  });

  late _JSMarker marker;
  double lng;
  double lat;
  double rotation;
  Uint8List? iconBytes;
  String? iconUrl;
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
      onReady?.call();
    }).toJS);

    // Sources/layers vanish on every style switch — restore + re-theme.
    _map.on('style.load', ((JSAny? _) {
      _styleReady = true;
      _restoreOverlays();
      if (_navyGoldApplied) _applyThemeNow();
    }).toJS);

    _map.on('click', ((JSAny? event) {
      final cb = onMapTap;
      if (cb == null || event == null) return;
      final lngLat = _JSMapMouseEvent._(event as JSObject).lngLat;
      if (lngLat == null) return;
      cb(lngLat.lng, lngLat.lat);
    }).toJS);

    _map.on('move', ((JSAny? _) {
      onCameraMove?.call(_map.getZoom(), _map.getBearing(), _map.getPitch());
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
    _map.flyTo(_js({
      'center': [lng, lat],
      if (zoom != null) 'zoom': zoom,
      if (bearing != null) 'bearing': bearing,
      if (pitch != null) 'pitch': pitch,
      'duration': durationMs,
      'essential': true,
    }) as JSObject);
  }

  @override
  void fitBounds(
    List<LngLatPoint> points, {
    double paddingTop = 60,
    double paddingLeft = 60,
    double paddingBottom = 60,
    double paddingRight = 60,
    int durationMs = 1000,
  }) {
    if (points.isEmpty) return;
    if (points.length == 1) {
      flyTo(lng: points.first.lng, lat: points.first.lat, durationMs: durationMs);
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
        'maxZoom': 17,
      }) as JSObject,
    );
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

  _JSElement? _iconElement(Uint8List? bytes, String? url) {
    if (bytes == null && url == null) return null;
    final img = _document.createElement('img');
    img.src = url ?? 'data:image/png;base64,${base64Encode(bytes!)}';
    img.style
      ..width = '40px'
      ..height = '40px'
      ..display = 'block';
    return img;
  }

  _JSMarker _createJsMarker(_MarkerEntry e) {
    final opts = _JSMarkerOptions._(JSObject());
    final el = _iconElement(e.iconBytes, e.iconUrl);
    if (el != null) opts.element = el;
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
  }) {
    removeMarker(id);
    final entry = _MarkerEntry(
      lng: lng,
      lat: lat,
      rotation: rotation,
      iconBytes: iconBytes,
      iconUrl: iconUrl,
    );
    entry.marker = _createJsMarker(entry);
    _markers[id] = entry;
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
    final existing = _map.getSource(sourceId);
    if (existing != null) {
      existing.setData(_js(_feature(spec)));
      return;
    }
    _map.addSource(
        sourceId,
        _js({'type': 'geojson', 'data': _feature(spec)}) as JSObject);
    _map.addLayer(_js({
      'id': sourceId,
      'type': 'line',
      'source': sourceId,
      'layout': {'line-cap': 'round', 'line-join': 'round'},
      'paint': {
        'line-color': spec.color,
        'line-width': spec.width,
        'line-opacity': 0.9,
      },
    }) as JSObject);
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

  void _paint(String layerId, String name, String value) {
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
    for (final id in ['road-label', 'road-label-simple']) {
      _paint(id, 'text-color', _roadLabel);
    }
    for (final id in ['road-number-shield', 'road-exit-shield']) {
      _paint(id, 'text-color', _gold);
    }
    for (final id in ['building', 'building-outline']) {
      _paint(id, 'fill-color', _building);
    }
    _paint('building', 'fill-extrusion-color', _building);
    for (final id in _poiLayers) {
      _layout(id, 'visibility', 'visible');
      _paint(id, 'text-color', _poiText);
    }
    for (final id in _placeLayers) {
      _paint(id, 'text-color', _placeLabel);
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
    this.styleUri,
    this.onControllerCreated,
  });

  final double initialLng;
  final double initialLat;
  final double initialZoom;

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
    options.attributionControl = false;

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
