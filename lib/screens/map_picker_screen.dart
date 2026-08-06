import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../config/api_keys.dart';
import '../map/map_surface_coordinator.dart';
import '../map/web_map_view.dart';
import '../config/app_theme.dart';
import '../config/map_theme.dart';
import '../config/mapbox_config.dart';
import '../l10n/app_localizations.dart';
import '../models/lat_lng.dart';
import '../services/places_service.dart';
import '../services/map_controller_cache.dart';
import '../widgets/map/circular_pin_renderer.dart';
import '../widgets/neu_style.dart';

/// Full-screen map picker. User drags the map under a fixed center pin.
/// Returns a Map with 'address' (String), 'lat' (double), 'lng' (double).
class MapPickerScreen extends StatefulWidget {
  final double? initialLat;
  final double? initialLng;
  /// When true the pin shows a person icon and button says "Confirm Pickup".
  /// When false (default) pin shows a location icon and button says "Confirm Dropoff".
  final bool isPickup;
  const MapPickerScreen({super.key, this.initialLat, this.initialLng, this.isPickup = false});

  @override
  State<MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<MapPickerScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  final _places = PlacesService(ApiKeys.webServices);

  /// Identifies this screen to [MapSurfaceCoordinator].
  ///
  /// This screen is opened from the booking flow, which has a full-screen
  /// map of its own. Mounting ours on top of it was two live Mapbox
  /// surfaces, which closes the app on iOS. The coordinator revokes the
  /// screen underneath and waits for it to be gone before we mount.
  static const String _mapSurfaceOwner = 'MapPicker';
  bool _mapMounted = false;

  mapbox.MapboxMap? _mapCtrl;
  // Web counterpart — GL JS surface behind the kIsWeb guard in build().
  WebMapController? _webMapCtrl;
  String _address = '';
  bool _addressIsPlaceholder = true;
  bool _loading = false;
  bool _geocodeFailed = false;
  // Birmingham, the same seed preload_service and the request flow already
  // use. This was New York — a default nobody chose, a thousand miles from
  // every real user, so the map opened over Manhattan and then jumped to
  // Alabama the moment GPS answered. That jump is what reads as the map
  // resetting itself.
  LatLng _center = const LatLng(33.5186, -86.8104);

  /// Set the first time the rider pans or zooms. From then on the camera is
  /// theirs and [_resolveGpsCenter] must not fly it anywhere.
  bool _userMovedMap = false;
  Timer? _debounce;
  int _geocodeGen = 0; // generation counter to cancel stale requests
  late final AnimationController _settleCtrl;
  late final Animation<double> _settleAnim;

  // Confirm anchor animation
  AnimationController? _anchorCtrl;
  Animation<double>? _anchorAnim;
  bool _confirming = false;
  Ticker? _rippleTicker;
  double _rippleElapsed = 0.0;
  static const _rippleDurationMs = 1200.0;
  static const _waveCount = 3; // number of staggered waves

  @override
  void initState() {
    super.initState();
    unawaited(_acquireMapSurface());
    _settleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _settleAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.05), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.05, end: 1.0), weight: 50),
    ]).animate(CurvedAnimation(parent: _settleCtrl, curve: Curves.easeOut));
    if (widget.initialLat != null && widget.initialLng != null) {
      _center = LatLng(widget.initialLat!, widget.initialLng!);
    } else {
      _resolveGpsCenter();
    }
  }

  /// When no initial coordinates are provided, fly map to the user's GPS location.
  Future<void> _resolveGpsCenter() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 5));
      if (!mounted) return;
      // A high-accuracy fix can take the whole 5s. If the rider has already
      // started aiming the map in the meantime, this flight is not a helpful
      // default any more — it is the map being pulled out of their hands.
      //
      // _center is left alone too, not just the camera: once the rider has
      // aimed, the camera is what Confirm commits, and overwriting the centre
      // here would hand them an address for a place they never pointed at.
      if (_userMovedMap) {
        debugPrint('[MapPicker] GPS fix arrived after the rider moved the '
            'map — keeping their camera and centre');
        return;
      }
      _center = LatLng(pos.latitude, pos.longitude);
      // Same fix on the web surface — the native controller is null there.
      _webMapCtrl?.flyTo(
        lng: pos.longitude,
        lat: pos.latitude,
        zoom: 15.0,
        durationMs: 800,
      );
      final map = _mapCtrl;
      if (map != null) {
        await map.flyTo(
          mapbox.CameraOptions(
            center: mapbox.Point(
              coordinates: mapbox.Position(pos.longitude, pos.latitude),
            ),
            zoom: 15.0,
          ),
          mapbox.MapAnimationOptions(duration: 800),
        );
      }
    } catch (e) {
      // Not fatal — the default centre still works — but silence here meant
      // a picker that opened on the wrong city looked like a map bug.
      debugPrint('[MapPicker] GPS centre unavailable, keeping default: $e');
    }
  }

  /// Claim the one live Mapbox surface before mounting the map.
  Future<void> _acquireMapSurface() async {
    await MapSurfaceCoordinator.instance.acquire(
      owner: _mapSurfaceOwner,
      onRevoke: () async {
        if (!mounted || !_mapMounted) return;
        setState(() => _mapMounted = false);
        await surfaceRemoved();
      },
    );
    if (!mounted) {
      MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
      return;
    }
    setState(() => _mapMounted = true);
  }

  @override
  void dispose() {
    MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
    _debounce?.cancel();
    _settleCtrl.dispose();
    _anchorCtrl?.dispose();
    _rippleTicker?.dispose();
    super.dispose();
  }

  void _scheduleGeocode() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _onCameraIdle);
  }

  Future<void> _onCameraIdle() async {
    _debounce?.cancel();
    if (!mounted) return;
    final gen = ++_geocodeGen;
    final snap = LatLng(_center.latitude, _center.longitude);
    if (_addressIsPlaceholder || _geocodeFailed) {
      setState(() {
        _loading = true;
        _geocodeFailed = false;
      });
    }
    String? addr;
    for (int attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted || gen != _geocodeGen) return;
      try {
        addr = await _places.reverseGeocode(
          lat: snap.latitude,
          lng: snap.longitude,
        );
        if (addr != null && addr.isNotEmpty) break;
      } catch (_) {}
    }
    if (!mounted || gen != _geocodeGen) return;
    setState(() {
      if (addr != null && addr.isNotEmpty) {
        _address = addr;
        _addressIsPlaceholder = false;
        _geocodeFailed = false;
      } else {
        _addressIsPlaceholder = true;
        _geocodeFailed = true;
      }
      _loading = false;
    });
  }

  void _onMapIdle(mapbox.MapIdleEventData event) {
    // Settle bounce on pin
    _settleCtrl.forward(from: 0);
    // Mapbox fires onMapIdle — schedule geocode
    _scheduleGeocode();
  }

  void _onCameraChanged(mapbox.CameraChangedEventData event) {
    // Update center on every camera change
    final map = _mapCtrl;
    if (map == null) return;
    map.getCameraState().then((state) {
      // The screen can pop while this platform call is in flight; writing the
      // centre afterwards would leave Confirm holding a coordinate from a
      // camera nobody is looking at any more.
      if (!mounted) return;
      final coords = state.center.coordinates;
      _center = LatLng(coords.lat.toDouble(), coords.lng.toDouble());
    }).catchError((Object e) {
      // Was an unhandled async error: getCameraState throws once the surface
      // is gone, and _center then silently kept a stale value.
      debugPrint('[MapPicker] camera read failed: $e');
    });
  }

  void _confirm() {
    if (_addressIsPlaceholder || _address.isEmpty || _confirming) {
      return;
    }
    setState(() => _confirming = true);

    // 1. Pin anchor drop animation (bounce spring)
    _anchorCtrl?.dispose();
    _anchorCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _anchorAnim = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: -18.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 25,
      ),
      TweenSequenceItem(
        tween: Tween(begin: -18.0, end: 4.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 40,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 4.0, end: -2.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 20,
      ),
      TweenSequenceItem(
        tween: Tween(begin: -2.0, end: 0.0)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 15,
      ),
    ]).animate(_anchorCtrl!);
    _anchorCtrl!.addListener(() => setState(() {}));
    _anchorCtrl!.forward(from: 0);

    // 2. Map-native ripple: add GeoJSON source + circle layers, animate with Ticker
    Future.delayed(const Duration(milliseconds: 260), () {
      if (!mounted) return;
      _startMapRipple();
    });

    // 3. Capture the current camera state so the next screen can boot
    //    its own map at exactly the same view → no teleport on handoff.
    () async {
      double? zoom, bearing, pitch;
      try {
        final cam = await _mapCtrl?.getCameraState();
        if (cam != null) {
          zoom = cam.zoom;
          bearing = cam.bearing;
          pitch = cam.pitch;
        }
      } catch (_) {}

      await Future.delayed(const Duration(milliseconds: 1400));
      if (!mounted) return;
      Navigator.of(context).pop({
        'address': _address,
        'lat': _center.latitude,
        'lng': _center.longitude,
        if (zoom != null) 'zoom': zoom,
        if (bearing != null) 'bearing': bearing,
        if (pitch != null) 'pitch': pitch,
      });
    }();
  }

  /// Meters-per-pixel at a given latitude and zoom level.
  double _metersPerPixel(double lat, double zoom) {
    return 156543.03392 *
        (1.0 / (1 << zoom.floor())) *
        (1.0 / (1.0 + (lat.abs() * 3.14159265 / 180.0).clamp(0.0, 1.2)));
  }

  /// Generate a GeoJSON Polygon approximating a geodesic circle of
  /// [radiusMeters] around (lat,lng). 64 vertices is plenty smooth at
  /// city zoom and keeps the per-frame update cheap.
  Map<String, dynamic> _circlePolygon(double lat, double lng, double radiusMeters) {
    const steps = 64;
    const earthRadius = 6378137.0; // meters
    final coords = <List<double>>[];
    final latRad = lat * math.pi / 180.0;
    for (int i = 0; i <= steps; i++) {
      final theta = 2 * math.pi * (i / steps);
      final dx = radiusMeters * math.cos(theta);
      final dy = radiusMeters * math.sin(theta);
      final dLng = (dx / (earthRadius * math.cos(latRad))) * 180.0 / math.pi;
      final dLat = (dy / earthRadius) * 180.0 / math.pi;
      coords.add([lng + dLng, lat + dLat]);
    }
    return {
      'type': 'Feature',
      'geometry': {
        'type': 'Polygon',
        'coordinates': [coords],
      },
      'properties': {},
    };
  }

  Future<void> _startMapRipple() async {
    final map = _mapCtrl;
    if (map == null) return;

    final lng = _center.longitude;
    final lat = _center.latitude;

    // Add a per-wave GeoJSON source + Fill layer. We use FillLayer (not
    // CircleLayer) so the rings are real ground polygons that inherit
    // the map's pitch — when the camera is tilted they read as ellipses
    // on the road instead of flat overlay circles in screen space.
    for (int i = 0; i < _waveCount; i++) {
      final sourceId = 'ripple-source-$i';
      final fillLayerId = 'ripple-fill-$i';
      final lineLayerId = 'ripple-line-$i';
      try {
        await map.style.addSource(mapbox.GeoJsonSource(
          id: sourceId,
          data: jsonEncode({
            'type': 'FeatureCollection',
            'features': [_circlePolygon(lat, lng, 0.5)],
          }),
        ));
      } catch (_) {}
      try {
        // Soft gold fill — barely there at peak.
        await map.style.addLayer(mapbox.FillLayer(
          id: fillLayerId,
          sourceId: sourceId,
          fillColor: 0xFFD4A843,
          fillOpacity: 0.0,
        ));
      } catch (_) {}
      try {
        // Crisper gold edge so the ring is readable.
        await map.style.addLayer(mapbox.LineLayer(
          id: lineLayerId,
          sourceId: sourceId,
          lineColor: 0xFFE8C547,
          lineWidth: 2.5,
          lineOpacity: 0.0,
        ));
      } catch (_) {}
    }

    // Animate using Ticker for smooth 60fps
    _rippleElapsed = 0.0;
    _rippleTicker?.dispose();
    _rippleTicker = createTicker((elapsed) {
      _rippleElapsed = elapsed.inMilliseconds.toDouble();
      if (_rippleElapsed > _rippleDurationMs) {
        _rippleTicker?.stop();
        _cleanupMapRipple();
        return;
      }
      _updateRippleLayers();
    })..start();
  }

  void _updateRippleLayers() {
    final map = _mapCtrl;
    if (map == null) return;

    final lat = _center.latitude;
    final lng = _center.longitude;

    for (int i = 0; i < _waveCount; i++) {
      final sourceId = 'ripple-source-$i';
      final fillLayerId = 'ripple-fill-$i';
      final lineLayerId = 'ripple-line-$i';
      // Stagger each wave by 150ms
      final waveOffset = i * 150.0;
      final waveTime = (_rippleElapsed - waveOffset).clamp(0.0, _rippleDurationMs - waveOffset);
      final progress = (waveTime / (_rippleDurationMs - waveOffset)).clamp(0.0, 1.0);

      if (progress <= 0) continue;

      // Ease out curve for natural deceleration
      final eased = 1.0 - (1.0 - progress) * (1.0 - progress);
      // Max radius grows with each wave (outer waves go further).
      // GeoJSON polygons use METERS — at zoom 15 the previous 80-110px
      // values map roughly to 35-55m on the ground. Tweak feels good
      // for typical pickup spots.
      final maxRadiusM = 35.0 + (i * 14.0);
      final radiusM = maxRadiusM * eased;
      final opacity = progress < 0.15
          ? (progress / 0.15) * 0.35
          : 0.35 * (1.0 - ((progress - 0.15) / 0.85));
      final fillOpacity = opacity * 0.25;
      final strokeOpacity = opacity;
      final strokeWidth = (3.0 * (1.0 - eased * 0.5)).clamp(0.5, 3.0);

      // Update the source geometry so the polygon expands. Mapbox
      // re-renders projected onto the ground plane — pitch comes for
      // free, the rings now sit on the road instead of on the screen.
      try {
        (map.style as dynamic).updateGeoJSONSourceFeatures(
          sourceId,
          'ripple-feature',
          [_circlePolygon(lat, lng, radiusM.clamp(0.5, double.infinity))],
        );
      } catch (_) {
        // Fallback: replace whole source data string.
        try {
          map.style.setStyleSourceProperty(
            sourceId,
            'data',
            jsonEncode({
              'type': 'FeatureCollection',
              'features': [_circlePolygon(lat, lng, radiusM.clamp(0.5, double.infinity))],
            }),
          );
        } catch (_) {}
      }
      map.style.setStyleLayerProperty(fillLayerId, 'fill-opacity', fillOpacity);
      map.style.setStyleLayerProperty(lineLayerId, 'line-opacity', strokeOpacity);
      map.style.setStyleLayerProperty(lineLayerId, 'line-width', strokeWidth);
    }
  }

  Future<void> _cleanupMapRipple() async {
    final map = _mapCtrl;
    if (map == null) return;
    for (int i = 0; i < _waveCount; i++) {
      try { await map.style.removeStyleLayer('ripple-fill-$i'); } catch (_) {}
      try { await map.style.removeStyleLayer('ripple-line-$i'); } catch (_) {}
      try { await map.style.removeStyleSource('ripple-source-$i'); } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final canConfirm = !_loading &&
        !_confirming &&
        !_addressIsPlaceholder &&
        _address.isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFF0A1128),
      body: Stack(
        children: [
          // ── Map ──
          if (!_mapMounted)
            const Positioned.fill(
              child: ColoredBox(color: Color(0xFF0A1128)),
            )
          // The native MapWidget has no web implementation — GL JS takes
          // over in the browser. Camera drags feed the same debounced
          // reverse-geocode the native onCameraChange/onMapIdle pair drives.
          else if (kIsWeb)
          RepaintBoundary(
            child: WebMapView(
              key: const ValueKey('map_picker_web'),
              initialLng: _center.longitude,
              initialLat: _center.latitude,
              initialZoom: 15.0,
              styleUri: MapboxConfig.styleDark,
              onControllerCreated: (c) {
                _webMapCtrl = c;
                c.applyNavyGoldTheme();
                // Only the hand reaches onUserGesture; onCameraMove below
                // also fires for our own flights and would latch on the very
                // move the latch exists to stop.
                c.onUserGesture = () => _userMovedMap = true;
                c.onCameraMove = (_, __, ___) {
                  final ctr = c.getCenter();
                  _center = LatLng(ctr.lat, ctr.lng);
                  _settleCtrl.forward(from: 0);
                  _scheduleGeocode();
                };
                Future.delayed(
                    const Duration(milliseconds: 800), _onCameraIdle);
              },
            ),
          )
          else
          RepaintBoundary(
            child: mapbox.MapWidget(
              textureView: true,
              styleUri: MapboxConfig.styleDark,
              onMapLoadErrorListener: (err) => debugPrint('[MapPicker] Load error: ${err.message} (type: ${err.type})'),
              cameraOptions: mapbox.CameraOptions(
                center: mapbox.Point(
                    coordinates: mapbox.Position(
                        _center.longitude, _center.latitude)),
                zoom: 15.0,
              ),
              onMapCreated: (ctrl) async {
                _mapCtrl = ctrl;
                // Cache controller for reuse across rider screens
                MapControllerCache.instance.cache(ctrl);
                ctrl.scaleBar.updateSettings(
                    mapbox.ScaleBarSettings(enabled: false));
                ctrl.compass
                    .updateSettings(mapbox.CompassSettings(enabled: false));
                ctrl.attribution.updateSettings(
                    mapbox.AttributionSettings(enabled: false));
                ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));
                Future.delayed(
                    const Duration(milliseconds: 800), _onCameraIdle);
              },
              onStyleLoadedListener: (_) async {
                if (_mapCtrl != null) await MapTheme.applyNavyGold(_mapCtrl!);
              },
              // The picker's whole job is letting the rider aim the map, so
              // the moment they touch it the camera is theirs. Without this
              // the GPS resolution below could still be in flight — up to 5s
              // — and its flyTo tore the map out from under the drag.
              // onCameraChangeListener cannot serve here: it also fires for
              // our own flights, so it would latch on the very move it is
              // meant to prevent.
              onScrollListener: (_) => _userMovedMap = true,
              onZoomListener: (_) => _userMovedMap = true,
              onCameraChangeListener: _onCameraChanged,
              onMapIdleListener: _onMapIdle,
            ),
          ),

          // ── Floating center pin (teardrop with bounce + settle) ──
          Center(
            child: Transform.translate(
              offset: Offset(0, -(46 * 1.0 / 2) + (_anchorAnim?.value ?? 0.0)),
              child: ScaleTransition(
                scale: _settleAnim,
                child: CircularMapPin(
                  size: 46,
                  icon: widget.isPickup
                      ? CircularPinIcon.person
                      : CircularPinIcon.flag,
                  isPickup: widget.isPickup,
                ),
              ),
            ),
          ),

          // ── Top bar: back button + context title pill ──
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            left: 0,
            right: 0,
            child: Row(
              children: [
                const SizedBox(width: 14),
                _MapBackBtn(onTap: () => Navigator.of(context).pop()),
                Expanded(
                  child: Center(
                    child: _MapTitlePill(
                      text: widget.isPickup
                          ? s.moveMapToSetPickup
                          : s.moveMapToSetDropoff,
                    ),
                  ),
                ),
                const SizedBox(width: 54), // balance back button width
              ],
            ),
          ),

          // ── Bottom card, flush to the screen ──
          //
          // It used to float with 10 px of map showing down both sides and
          // underneath, so it read as a slab dropped on top rather than as
          // the bottom of the screen. Anchored to the three edges instead,
          // rounded only where it meets the map.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _FooterCard(
              title: widget.isPickup ? s.setYourPickup : s.setYourDropoff,
              subtitle: widget.isPickup
                  ? s.moveMapToPreferredPickup
                  : s.moveMapToPreferredDropoff,
              address: _addressIsPlaceholder || _address.isEmpty
                  ? (_loading ? s.findingAddress : s.pinnedLocation)
                  : _address,
              addressDim: _addressIsPlaceholder || _address.isEmpty,
              geocodeFailed: _geocodeFailed,
              onRetry: _geocodeFailed ? _onCameraIdle : null,
              canConfirm: canConfirm,
              onConfirm: _confirm,
              confirmLabel: s.confirmLabel,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Top bar widgets (back button + title pill)
// ═══════════════════════════════════════════════════════════════════

class _MapBackBtn extends StatelessWidget {
  final VoidCallback onTap;
  const _MapBackBtn({required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Pressed neumorphic circle (same language as the other back buttons).
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 40,
          height: 40,
          decoration: neuBox(radius: 14, pressed: true),
          alignment: Alignment.center,
          child: const Icon(Icons.arrow_back_rounded,
              color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

class _MapTitlePill extends StatelessWidget {
  final String text;
  const _MapTitlePill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.72,
      ),
      decoration: neuBox(radius: 20),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: 'Poppins',
          color: Colors.white.withValues(alpha: 0.78),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Footer card (title + subtitle + address card + gold confirm)
// ═══════════════════════════════════════════════════════════════════

class _FooterCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final String address;
  final bool addressDim;
  final bool geocodeFailed;
  final VoidCallback? onRetry;
  final bool canConfirm;
  final VoidCallback onConfirm;
  final String confirmLabel;

  const _FooterCard({
    required this.title,
    required this.subtitle,
    required this.address,
    required this.addressDim,
    required this.geocodeFailed,
    required this.onRetry,
    required this.canConfirm,
    required this.onConfirm,
    required this.confirmLabel,
  });

  @override
  State<_FooterCard> createState() => _FooterCardState();
}

class _FooterCardState extends State<_FooterCard> {
  bool _btnPressed = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          20,
          22,
          20,
          22 + MediaQuery.of(context).padding.bottom),
      // Top corners only — the other two are off-screen now.
      decoration: neuBox(radius: 24).copyWith(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.title,
            style: const TextStyle(
              fontFamily: 'Poppins',
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.subtitle,
            style: TextStyle(
              fontFamily: 'Poppins',
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 14),

          // Address card — sunken neumorphic well, gold icon accent
          GestureDetector(
            onTap: widget.onRetry,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: neuBox(radius: 14, pressed: true),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: const BoxDecoration(
                      color: Color(0x1FE8C547),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.search_rounded,
                        color: Color(0xFFE8C547), size: 16),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          S.of(context).locationCaps,
                          style: TextStyle(
                            fontFamily: 'Poppins',
                            color: const Color(0xFFE8C547)
                                .withValues(alpha: 0.75),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.4,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.address,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Poppins',
                            color: Colors.white.withValues(
                                alpha: widget.addressDim ? 0.45 : 1.0),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.geocodeFailed)
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(Icons.refresh_rounded,
                          color: Color(0xFFE8C547), size: 18),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Confirm button (gold gradient)
          GestureDetector(
            onTap: widget.canConfirm ? widget.onConfirm : null,
            onTapDown: widget.canConfirm
                ? (_) => setState(() => _btnPressed = true)
                : null,
            onTapCancel: () => setState(() => _btnPressed = false),
            onTapUp: (_) => setState(() => _btnPressed = false),
            child: AnimatedScale(
              scale: _btnPressed ? 0.97 : 1.0,
              duration: const Duration(milliseconds: 120),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 160),
                opacity: widget.canConfirm ? 1.0 : 0.35,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFFF5DC7A),
                        Color(0xFFE8C547),
                        Color(0xFFD4A800),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(100),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFE8C547).withValues(alpha: 0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    widget.confirmLabel,
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      color: Color(0xFF0A0E1A),
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

