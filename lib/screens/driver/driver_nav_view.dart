import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../../config/api_keys.dart';
import '../../config/map_theme.dart';
import '../../config/mapbox_config.dart';
import '../../l10n/app_localizations.dart';
import '../../map/map_surface_coordinator.dart';
import '../../map/web_map_view.dart';
import '../../models/lat_lng.dart';
import '../../services/directions_service.dart';
import '../../services/haptic_service.dart';
import '../../services/resilient_position_stream.dart';
import '../../services/socket_service.dart';
import '../../utils/driver_location_settings.dart';
import '../../utils/mapbox_safe.dart';
import '../../utils/smooth_motion.dart';
import '../../widgets/gold_location_dot.dart';
import '../../widgets/neu_style.dart';
import '../../widgets/verified_avatar.dart';

/// Full-screen in-app turn-by-turn navigation, Google Maps-style in navy/gold:
/// maneuver bar on top, live mph box, a draggable rider sheet at the bottom,
/// and the driver's gold arrow chased by a 17.5/55° camera.
///
/// It mounts the app's ONE native Mapbox surface, claimed from
/// [MapSurfaceCoordinator] under an owner id unique per instance — the
/// accept screen's mini map has already let go before this widget exists.
///
/// Stage controls (Arrived → wait bar → slide to pick up → slide to finish)
/// are driven by [stage], computed by the parent from its own trip state, and
/// every action calls back into the parent's existing handlers — this view
/// never talks to the backend itself.
class DriverNavView extends StatefulWidget {
  const DriverNavView({
    super.key,
    required this.tripId,
    required this.riderName,
    required this.riderPhotoUrl,
    required this.riderId,
    required this.pickupLatLng,
    required this.dropoffLatLng,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.fare,
    required this.initialDriverPos,
    required this.toPickup,
    required this.stage,
    required this.passengerInstructions,
    required this.dropoffInstructions,
    required this.waitStartedAt,
    required this.onExit,
    required this.onArrived,
    required this.onSlidePickUp,
    required this.onSlideFinish,
    required this.onOpenChat,
    required this.onCall,
    required this.onSupport,
    this.onMapReady,
  });

  final int tripId;
  final String riderName;
  final String riderPhotoUrl;
  final int? riderId;
  final LatLng pickupLatLng;
  final LatLng dropoffLatLng;
  final String pickupAddress;
  final String dropoffAddress;
  final double fare;
  final LatLng initialDriverPos;

  /// Pickup leg (going for the rider) vs dropoff leg (rider aboard). The leg
  /// flip also hides the rider figure — there is nobody left to walk to.
  final bool toPickup;

  /// The parent screen's `_actionStageKey()`: arrived / waiting_rider /
  /// start_ride / finish / *_locked.
  final String stage;

  final String passengerInstructions;
  final String dropoffInstructions;

  /// Backend wait-start timestamp parsed from the notes line, when present —
  /// the wait divider drains from this so a reopened screen stays in sync.
  final DateTime? waitStartedAt;

  final VoidCallback onExit;
  final VoidCallback onArrived;
  final VoidCallback onSlidePickUp;
  final VoidCallback onSlideFinish;
  final VoidCallback onOpenChat;
  final VoidCallback onCall;
  final VoidCallback onSupport;

  /// Fired when the native map has its first controller — the parent
  /// cross-fades its expansion snapshot out on this signal.
  final VoidCallback? onMapReady;

  @override
  State<DriverNavView> createState() => _DriverNavViewState();
}

class _DriverNavViewState extends State<DriverNavView>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const _gold = Color(0xFFE8C547);
  static const _navyBar = Color(0xFF0A1128);

  // Unique per instance: this view can be re-mounted over a surface another
  // screen still holds, and a shared static id is what made the coordinator
  // skip the revoke (two native maps = iOS crash). Same pattern as
  // ride_request_screen's _mapSurfaceOwner.
  static int _nextMapSurfaceId = 0;
  late final String _mapSurfaceOwner = 'DriverTripNav-${++_nextMapSurfaceId}';
  bool _mapMounted = false;

  mapbox.MapboxMap? _map;
  mapbox.PolylineAnnotationManager? _polyMgr;
  mapbox.PointAnnotationManager? _pointMgr;
  mapbox.PolylineAnnotation? _routeAnnot;
  mapbox.PointAnnotation? _driverAnnot;
  mapbox.PointAnnotation? _destAnnot;
  bool _annotWriteBusy = false;

  // ── Driver marker: the same GoldLocationDot + SmoothMotion as the online
  //    map. onTick (throttled) writes the annotation; onFrame chases. ──
  final GoldLocationDot _dot = GoldLocationDot(heading: true);

  // ── Rider figure (pickup leg only) ──
  final SmoothMotion _riderMotion = SmoothMotion();
  Ticker? _riderTicker;
  Duration _riderLastTick = Duration.zero;
  mapbox.PointAnnotation? _riderAnnot;
  Uint8List? _riderFigureBytes;
  DateTime? _riderFixAt;
  Timer? _riderStaleTimer;
  Offset? _riderLabelPos;
  int _riderStaleSecs = 0;

  // ── Camera ──
  bool _follow = true;
  bool _overview = false;
  mapbox.CameraOptions? _pendingCamWrite;
  bool _camWriteBusy = false;

  // ── Route + maneuvers ──
  List<LatLng> _routePts = [];
  NavProgress? _navProgress;
  bool _routeFetching = false;
  String _streetLabel = '';
  String _thenLabel = '';
  String _maneuverDistLabel = '';
  String _maneuverType = 'depart';
  String _maneuverModifier = '';
  double _speedMps = 0;
  int _lastMphShown = -1;
  int _remainSecs = 0;
  double _remainMeters = 0;

  // ── Stage controls ──
  double _slideVal = 0;
  bool _slideDone = false;
  String _lastStageSynced = '';
  Timer? _waitTicker;
  DateTime? _waitStartLocal; // fallback clock when notes carry no timestamp
  double _waitRemainFrac = 1.0;
  String _waitClock = '5:00';
  static const _waitTotalSecs = 300;
  static const _stageControlHeight = 62.0;

  ResilientPositionStream? _gps;
  StreamSubscription? _riderLocSub;
  WebMapController? _webMap;

  final DraggableScrollableController _sheetCtrl =
      DraggableScrollableController();

  LatLng get _dest =>
      widget.toPickup ? widget.pickupLatLng : widget.dropoffLatLng;

  bool get _stageControlVisible =>
      widget.stage == 'arrived' ||
      widget.stage == 'start_ride' ||
      widget.stage == 'finish';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _acquireMapSurface();
    // Drives the marker and hands the per-frame callbacks: onTick writes the
    // annotation (throttled by GoldLocationDot), onFrame chases the camera.
    _dot.build(this, _onDotTick, onFrame: _onDotFrame);
    _riderTicker = createTicker(_onRiderTick)..start();
    _listenRiderLocation();
    // Localizations and the first stage sync need a built context.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _startGps();
      _syncStageControls(widget.stage);
      _loadRoute();
    });
  }

  @override
  void didUpdateWidget(DriverNavView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stage != widget.stage) {
      _syncStageControls(widget.stage);
    }
    // Leg flip (pickup → dropoff): re-aim the route and drop the rider
    // figure — after the slide to pick up there is nobody left to show.
    if (oldWidget.toPickup != widget.toPickup) {
      _navProgress = null;
      _riderFixAt = null;
      if (_riderLabelPos != null) setState(() => _riderLabelPos = null);
      final annot = _riderAnnot;
      _riderAnnot = null;
      final mgr = _pointMgr;
      if (annot != null && mgr != null) {
        mgr.delete(annot).catchError((Object _) {});
      }
      _loadRoute();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
    _sheetCtrl.dispose();
    unawaited(_gps?.stop());
    _riderLocSub?.cancel();
    _riderStaleTimer?.cancel();
    _waitTicker?.cancel();
    _riderTicker?.dispose();
    _dot.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _gps?.onAppResumed();
    _dot.ensureRunning();
    // The surface may have been revoked (or Android destroyed the
    // PlatformView) while away — claim it back.
    if (!_mapMounted) _acquireMapSurface();
  }

  // ─────────────────────────────────────────────
  //  Map surface
  // ─────────────────────────────────────────────

  Future<void> _acquireMapSurface() async {
    await MapSurfaceCoordinator.instance.acquire(
      owner: _mapSurfaceOwner,
      onRevoke: () async {
        if (!mounted || !_mapMounted) return;
        // Every annotation handle belongs to the PlatformView being
        // destroyed — drop them so nothing writes to a dead channel.
        _map = null;
        _polyMgr = null;
        _pointMgr = null;
        _routeAnnot = null;
        _driverAnnot = null;
        _destAnnot = null;
        _riderAnnot = null;
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

  Future<void> _onMapCreated(mapbox.MapboxMap ctrl) async {
    _map = ctrl;
    // Each call stands alone so one refusal does not skip the rest.
    for (final step in <Future<void> Function()>[
      () => ctrl.scaleBar
          .updateSettings(mapbox.ScaleBarSettings(enabled: false)),
      () =>
          ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false)),
      () => ctrl.attribution
          .updateSettings(mapbox.AttributionSettings(enabled: false)),
      () => ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false)),
    ]) {
      try {
        await step();
      } catch (_) {}
    }
    _polyMgr = await ctrl.annotations.createPolylineAnnotationManager();
    _pointMgr = await ctrl.annotations.createPointAnnotationManager();
    try {
      final lid = _pointMgr!.id;
      await ctrl.style.setStyleLayerProperty(lid, 'icon-allow-overlap', true);
    } catch (_) {}
    // A recreated surface (app backgrounded on Android) loses everything —
    // redraw the route and destination pin from the State that survived.
    await _drawRoute();
    await _drawDestPin();
    widget.onMapReady?.call();
  }

  // ─────────────────────────────────────────────
  //  GPS → marker + maneuvers
  // ─────────────────────────────────────────────

  void _startGps() {
    // Foreground-only: the parent screen already runs the background stream
    // that publishes the driver's position; this one only feeds the marker
    // and the camera of a screen the driver is looking at. A second
    // foreground-service notification would read as a second tracker.
    final s = S.of(context);
    _gps = ResilientPositionStream(
      label: 'DriverNavGps',
      settings: driverLocationSettings(
        background: false,
        distanceFilter: 1,
        notificationTitle: s.driverLocationNotifTitle,
        notificationText: s.driverLocationNotifOnTrip,
      ),
      onPosition: _onGpsFix,
    )..start();
    // Seed the marker where the accept screen last had the driver, so the
    // arrow never slides in from (0,0) while the first fix is in flight.
    _dot.setTarget(
      widget.initialDriverPos.latitude,
      widget.initialDriverPos.longitude,
      timestampMs: DateTime.now().millisecondsSinceEpoch.toDouble(),
    );
  }

  void _onGpsFix(Position pos) {
    if (!mounted) return;
    _dot.setTarget(
      pos.latitude,
      pos.longitude,
      bearing: pos.heading >= 0 ? pos.heading : null,
      accuracyM: pos.accuracy,
      timestampMs: pos.timestamp.millisecondsSinceEpoch.toDouble(),
    );
    _speedMps = pos.speed.isFinite && pos.speed > 0 ? pos.speed : 0;
    final mph = (_speedMps * 2.23694).round();
    if (mph != _lastMphShown) {
      _lastMphShown = mph;
      setState(() {}); // the mph box is the only reader
    }
    _updateManeuvers(LatLng(pos.latitude, pos.longitude));
  }

  /// Advance the step tracker and repaint the bar — only when what the bar
  /// SAYS changed, so a driver sitting at a light causes no rebuilds.
  void _updateManeuvers(LatLng driverPos) {
    final nav = _navProgress;
    if (nav == null || !nav.hasSteps) return;
    nav.update(driverPos);
    final cur = nav.current;
    final s = S.of(context);
    final street =
        cur == null || cur.name.isEmpty ? s.navFollowRoute : cur.name;
    final dist = cur == null
        ? ''
        : _fmtDist(nav.distanceToCurrentMeters(driverPos), s);
    final then = nav.then == null || nav.then!.name.isEmpty
        ? ''
        : '${s.navThen} → ${nav.then!.name}';

    // Remaining trip = distance to the current maneuver plus every step
    // after it — the "9 min · 4.1 mi" of the sheet.
    var meters = cur == null ? 0.0 : nav.distanceToCurrentMeters(driverPos);
    var secs = 0;
    if (cur != null) {
      for (var i = nav.steps.indexOf(cur) + 1; i < nav.steps.length; i++) {
        meters += nav.steps[i].distanceMeters;
        secs += nav.steps[i].durationSeconds;
      }
    }

    final type = cur?.maneuverType ?? 'arrive';
    final modifier = cur?.modifier ?? '';
    if (street == _streetLabel &&
        dist == _maneuverDistLabel &&
        then == _thenLabel &&
        type == _maneuverType &&
        modifier == _maneuverModifier &&
        (secs - _remainSecs).abs() < 15) {
      return;
    }
    setState(() {
      _streetLabel = street;
      _maneuverDistLabel = dist;
      _thenLabel = then;
      _maneuverType = type;
      _maneuverModifier = modifier;
      _remainSecs = secs;
      _remainMeters = meters;
    });
  }

  /// Bilingual maneuver distance: EN feet/mi, ES m/km.
  String _fmtDist(double meters, S s) {
    if (s.isSpanish) {
      if (meters < 950) return '${meters.round()} m';
      return '${(meters / 1000).toStringAsFixed(1)} km';
    }
    final mi = meters / 1609.34;
    if (mi < 0.1) return '${(meters * 3.28084).round()} ft';
    return '${mi.toStringAsFixed(1)} mi';
  }

  // ─────────────────────────────────────────────
  //  Route
  // ─────────────────────────────────────────────

  Future<void> _loadRoute() async {
    if (_routeFetching) return;
    _routeFetching = true;
    try {
      final originLat = _dot.lat ?? widget.initialDriverPos.latitude;
      final originLng = _dot.lng ?? widget.initialDriverPos.longitude;
      final result = await DirectionsService(ApiKeys.webServices).getRoute(
        origin: LatLng(originLat, originLng),
        destination: _dest,
      );
      if (!mounted || result == null || result.points.length < 2) return;
      _routePts = result.points;
      _navProgress = NavProgress(result.steps);
      await _drawRoute();
      await _drawDestPin();
      await _fitRouteOnce();
      // Paint the first maneuver right away instead of waiting for a fix.
      if (mounted) {
        _updateManeuvers(LatLng(originLat, originLng));
      }
    } catch (e) {
      debugPrint('[Nav] route fetch failed: $e');
    } finally {
      _routeFetching = false;
    }
  }

  Future<void> _drawRoute() async {
    final mgr = _polyMgr;
    if (mgr == null) return;
    final geom = safeLineString(_routePts);
    if (geom == null) return;
    if (_routeAnnot != null) {
      _routeAnnot!.geometry = geom;
      try {
        await mgr.update(_routeAnnot!);
      } catch (_) {}
    } else {
      try {
        _routeAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
          geometry: geom,
          lineColor: _gold.toARGB32(),
          lineWidth: 5.0,
          lineJoin: mapbox.LineJoin.ROUND,
        ));
      } catch (_) {}
    }
  }

  Future<void> _drawDestPin() async {
    final mgr = _pointMgr;
    final point = safePoint(_dest.longitude, _dest.latitude);
    if (mgr == null || point == null) return;
    final old = _destAnnot;
    _destAnnot = null;
    if (old != null) {
      try {
        await mgr.delete(old);
      } catch (_) {}
    }
    try {
      _destAnnot = await mgr.create(mapbox.PointAnnotationOptions(
        geometry: point,
        textField: '★',
        textSize: 22,
        textColor: _gold.toARGB32(),
        textHaloColor: _navyBar.toARGB32(),
        textHaloWidth: 1.5,
      ));
    } catch (_) {}
  }

  /// One bounds fit when the route arrives, then the chase owns the camera.
  Future<void> _fitRouteOnce() async {
    final map = _map;
    if (map == null || _routePts.isEmpty) return;
    final media = MediaQuery.of(context);
    final coords = _routePts
        .where((p) => isValidLatLng(p.latitude, p.longitude))
        .map((p) =>
            mapbox.Point(coordinates: mapbox.Position(p.longitude, p.latitude)))
        .toList();
    if (coords.isEmpty) return;
    try {
      final cam = await map.cameraForCoordinatesPadding(
        coords,
        mapbox.CameraOptions(pitch: 0, bearing: 0),
        mapbox.MbxEdgeInsets(
          top: media.padding.top + 120,
          left: 48,
          bottom: media.size.height * 0.30,
          right: 48,
        ),
        null,
        null,
      );
      if (!mounted) return;
      // The overview toggle reuses this fit; chasing from it keeps follow on.
      await map.flyTo(cam, mapbox.MapAnimationOptions(duration: 900));
    } catch (e) {
      debugPrint('[Nav] route fit failed: $e');
    }
  }

  // ─────────────────────────────────────────────
  //  Per-frame: marker annotation + chase camera
  // ─────────────────────────────────────────────

  /// GoldLocationDot onTick — throttled (~30 fps), position changed.
  void _onDotTick() {
    _updateDriverAnnotation();
  }

  /// GoldLocationDot onFrame — unthrottled, repaint-rate. While following,
  /// the marker never moves on screen — the map slides under it — so the
  /// camera is the only thing to write per frame.
  void _onDotFrame() {
    if (!_follow || _overview || !_mapMounted) return;
    final lat = _dot.lat;
    final lng = _dot.lng;
    if (lat == null || lng == null) return;
    // Top padding pushes the focal point below centre (the car sits at
    // ~60% of the screen height, Google-Maps style) and keeps the arrow
    // clear of the maneuver bar.
    final topPad = (MediaQuery.maybeOf(context)?.padding.top ?? 0) + 130;
    _writeCamera(mapbox.CameraOptions(
      center: mapbox.Point(coordinates: mapbox.Position(lng, lat)),
      zoom: 17.5,
      bearing: _dot.bearing,
      pitch: 55,
      padding: mapbox.MbxEdgeInsets(top: topPad, left: 0, right: 0, bottom: 0),
    ));
  }

  /// Coalesced per-frame camera write — one in flight, one pending, ever.
  /// Same discipline as the online screen's _writeCamera: a dropped frame
  /// carries no information, the next one is already newer.
  void _writeCamera(mapbox.CameraOptions options) {
    if (kIsWeb) {
      final web = _webMap;
      final center = options.center?.coordinates;
      if (web == null || center == null) return;
      web.flyTo(
        lng: center.lng.toDouble(),
        lat: center.lat.toDouble(),
        zoom: options.zoom,
        bearing: options.bearing,
        pitch: options.pitch,
        durationMs: 0,
      );
      return;
    }
    final map = _map;
    if (map == null) return;
    _pendingCamWrite = options;
    if (_camWriteBusy) return;
    _flushCameraWrite(map);
  }

  void _flushCameraWrite(mapbox.MapboxMap map) {
    final opts = _pendingCamWrite;
    if (opts == null) return;
    _pendingCamWrite = null;
    _camWriteBusy = true;
    try {
      map.setCamera(opts).timeout(const Duration(seconds: 2)).then((_) {
        _camWriteBusy = false;
        _flushCameraWrite(map);
      }).catchError((Object _) {
        _camWriteBusy = false;
        _flushCameraWrite(map);
      });
    } catch (_) {
      _camWriteBusy = false;
    }
  }

  Future<void> _updateDriverAnnotation() async {
    if (!mounted || _annotWriteBusy) return;
    final mgr = _pointMgr;
    final lat = _dot.lat;
    final lng = _dot.lng;
    if (mgr == null || lat == null || lng == null) return;
    if (!isValidLatLng(lat, lng)) return;
    final img = _dot.currentBytesHiRes ?? _dot.currentBytes;
    if (img == null) return;
    _annotWriteBusy = true;
    try {
      if (_driverAnnot == null) {
        _driverAnnot = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(coordinates: mapbox.Position(lng, lat)),
          image: img,
          // Hi-res bitmap at 1/3 density lands at the overlay's size.
          iconSize: GoldLocationDot.driverIconSize /
              (_dot.currentBytesHiRes != null
                  ? GoldLocationDot.rasterScale
                  : 1.0),
          iconAnchor: mapbox.IconAnchor.CENTER,
          iconRotate: _dot.bearing,
        ));
        try {
          await _map?.style.setStyleLayerProperty(
              mgr.id, 'icon-rotation-alignment', 'map');
        } catch (_) {}
      } else {
        _driverAnnot!.geometry =
            mapbox.Point(coordinates: mapbox.Position(lng, lat));
        _driverAnnot!.iconRotate = _dot.bearing;
        await mgr.update(_driverAnnot!);
      }
    } catch (_) {
      // Annotation died with its surface — null it so the next tick
      // recreates it on the fresh map.
      _driverAnnot = null;
    } finally {
      _annotWriteBusy = false;
    }
  }

  // ─────────────────────────────────────────────
  //  Rider figure (pickup leg only)
  // ─────────────────────────────────────────────

  void _listenRiderLocation() {
    _riderLocSub = SocketService.riderLocationStream.listen((data) {
      if (!mounted) return;
      if ((data['trip_id'] as num?)?.toInt() != widget.tripId) return;
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      if (!isValidLatLng(lat, lng)) return;
      _riderFixAt = DateTime.now();
      _riderMotion.setTarget(
        lat!,
        lng!,
        bearing: (data['heading'] as num?)?.toDouble(),
        timestampMs: (data['captured_at'] as num?)?.toDouble(),
      );
      _armRiderStaleTimer();
    });
  }

  void _onRiderTick(Duration elapsed) {
    final dtSec = _riderLastTick == Duration.zero
        ? 0.0
        : (elapsed - _riderLastTick).inMicroseconds / 1e6;
    _riderLastTick = elapsed;
    if (!_riderMotion.tick(dtSec)) return;
    _updateRiderAnnotation();
  }

  Future<void> _updateRiderAnnotation() async {
    if (!mounted) return;
    // Pickup leg only: once the rider is aboard (slide to pick up done)
    // the figure hides with the leg flip.
    if (!widget.toPickup) return;
    final mgr = _pointMgr;
    final lat = _riderMotion.lat;
    final lng = _riderMotion.lng;
    if (mgr == null || lat == null || lng == null) return;
    if (!isValidLatLng(lat, lng)) return;
    final bytes = _riderFigureBytes ??= await _renderRiderFigure();
    if (bytes == null || !mounted) return;
    try {
      if (_riderAnnot == null) {
        _riderAnnot = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(coordinates: mapbox.Position(lng, lat)),
          image: bytes,
          iconSize: 1 / 3.0, // rendered at 3× density
          iconAnchor: mapbox.IconAnchor.CENTER,
        ));
      } else {
        _riderAnnot!.geometry =
            mapbox.Point(coordinates: mapbox.Position(lng, lat));
        await mgr.update(_riderAnnot!);
      }
    } catch (_) {
      _riderAnnot = null;
    }
  }

  /// Gold person over a translucent navy halo, rasterised once.
  Future<Uint8List?> _renderRiderFigure() async {
    const scale = 3.0, size = 46.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(scale);
    const center = Offset(size / 2, size / 2);
    canvas.drawCircle(
      center,
      size / 2,
      Paint()..color = _navyBar.withValues(alpha: 0.55),
    );
    canvas.drawCircle(
      center,
      size / 2 - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = _gold.withValues(alpha: 0.7),
    );
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(Icons.person_rounded.codePoint),
        style: TextStyle(
          fontFamily: Icons.person_rounded.fontFamily,
          package: Icons.person_rounded.fontPackage,
          fontSize: 27,
          color: _gold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
        canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
    try {
      final img = await recorder
          .endRecording()
          .toImage((size * scale).round(), (size * scale).round());
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      return data?.buffer.asUint8List();
    } catch (e) {
      debugPrint('[Nav] rider figure render failed: $e');
      return null;
    }
  }

  /// Fix older than 15 s → a subtle "hace Xs" next to the halo. The label is
  /// a Flutter widget (annotation text would need a re-raster per second);
  /// its anchor re-projects once a second, which the channel barely notices.
  void _armRiderStaleTimer() {
    _riderStaleTimer ??= Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted) return;
      final fixAt = _riderFixAt;
      if (fixAt == null || !widget.toPickup) {
        if (_riderLabelPos != null) setState(() => _riderLabelPos = null);
        return;
      }
      final age = DateTime.now().difference(fixAt).inSeconds;
      if (age <= 15) {
        if (_riderLabelPos != null) setState(() => _riderLabelPos = null);
        return;
      }
      final map = _map;
      final lat = _riderMotion.lat;
      final lng = _riderMotion.lng;
      if (map == null || lat == null || lng == null) return;
      try {
        final sc = await map.pixelForCoordinate(
            mapbox.Point(coordinates: mapbox.Position(lng, lat)));
        if (!mounted) return;
        setState(() {
          _riderStaleSecs = age;
          _riderLabelPos = Offset(sc.x, sc.y);
        });
      } catch (_) {}
    });
  }

  // ─────────────────────────────────────────────
  //  Stage controls (wait bar + slides)
  // ─────────────────────────────────────────────

  void _syncStageControls(String stage) {
    if (stage == _lastStageSynced) return;
    _lastStageSynced = stage;
    final waiting = stage == 'waiting_rider' || stage == 'start_ride';
    if (waiting && _waitTicker == null) {
      // The backend timestamp wins; a notes-less trip starts the clock when
      // the stage first shows.
      _waitStartLocal ??= DateTime.now();
      _tickWait();
      _waitTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) _tickWait();
      });
    }
    if (!waiting && _waitTicker != null) {
      _waitTicker?.cancel();
      _waitTicker = null;
    }
    // A new slide stage gets a fresh thumb.
    if (stage == 'start_ride' || stage == 'finish') {
      _slideVal = 0;
      _slideDone = false;
    }
  }

  void _tickWait() {
    final start = widget.waitStartedAt ?? _waitStartLocal ?? DateTime.now();
    final elapsed = DateTime.now().difference(start).inSeconds;
    final remain = (_waitTotalSecs - elapsed).clamp(0, _waitTotalSecs);
    if (!mounted) return;
    setState(() {
      _waitRemainFrac = remain / _waitTotalSecs;
      _waitClock =
          '${remain ~/ 60}:${(remain % 60).toString().padLeft(2, '0')}';
    });
  }

  void _onSlideUpdate(double delta, double maxDrag) {
    if (_slideDone) return;
    setState(() {
      _slideVal = (_slideVal + delta / maxDrag).clamp(0.0, 1.0);
    });
    if (_slideVal >= 0.88) {
      setState(() => _slideDone = true);
      HapticService.heavyImpact();
      if (widget.stage == 'start_ride') {
        widget.onSlidePickUp();
      } else {
        widget.onSlideFinish();
      }
    }
  }

  // ─────────────────────────────────────────────
  //  Camera buttons
  // ─────────────────────────────────────────────

  void _toggleOverview() {
    HapticService.lightImpact();
    setState(() {
      _overview = !_overview;
      _follow = !_overview;
    });
    if (_overview) _fitRouteOnce();
  }

  void _recenter() {
    HapticService.lightImpact();
    setState(() {
      _follow = true;
      _overview = false;
    });
  }

  void _onUserGesture() {
    if (!_follow) return;
    setState(() => _follow = false);
  }

  // ─────────────────────────────────────────────
  //  Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final media = MediaQuery.of(context);
    return Stack(
      children: [
        // ── Map ──
        Positioned.fill(
          child: _mapMounted && !kIsWeb
              ? RepaintBoundary(
                  child: mapbox.MapWidget(
                    textureView: true,
                    styleUri: MapboxConfig.styleDark,
                    cameraOptions: mapbox.CameraOptions(
                      center: mapbox.Point(
                          coordinates: mapbox.Position(
                              widget.initialDriverPos.longitude,
                              widget.initialDriverPos.latitude)),
                      zoom: 15.0,
                    ),
                    onMapCreated: _onMapCreated,
                    onStyleLoadedListener: (_) async {
                      final m = _map;
                      if (m != null) await MapTheme.applyNavyGold(m);
                    },
                    // Gesture callbacks, not onCameraChangeListener: that one
                    // also fires for the per-frame chase and would unlatch
                    // follow on the very writes the chase performs.
                    onScrollListener: (_) => _onUserGesture(),
                    onZoomListener: (_) => _onUserGesture(),
                  ),
                )
              : kIsWeb
                  ? WebMapView(
                      initialLng: widget.initialDriverPos.longitude,
                      initialLat: widget.initialDriverPos.latitude,
                      initialZoom: 14,
                      styleUri: MapboxConfig.styleDark,
                      onControllerCreated: (c) {
                        _webMap = c;
                        c.applyNavyGoldTheme();
                        if (_routePts.length >= 2) {
                          c.setPolyline(
                            'navRoute',
                            [
                              for (final p in _routePts)
                                (lng: p.longitude, lat: p.latitude)
                            ],
                            color: '#E8C547',
                            width: 5,
                          );
                        }
                      },
                    )
                  : const NeuDotsBackdrop(),
        ),

        // ── Maneuver bar ──
        Positioned(
          top: media.padding.top + 10,
          left: 14,
          right: 14,
          child: _buildManeuverBar(s),
        ),

        // ── Sheet-anchored overlays: mph, camera buttons, wait bar and the
        //    stage control all ride the sheet's top edge, so they rebuild
        //    with the drag rather than a frame behind it. ──
        AnimatedBuilder(
          animation: _sheetCtrl,
          builder: (ctx, _) {
            final extent =
                _sheetCtrl.isAttached ? _sheetCtrl.size : 0.20;
            final lift = media.size.height * extent + 16;
            return Stack(
              children: [
                Positioned(
                  left: 16,
                  bottom: lift,
                  child: _buildSpeedBox(),
                ),
                Positioned(
                  right: 14,
                  bottom: lift,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _roundMapBtn(
                        icon: _overview
                            ? Icons.navigation_rounded
                            : Icons.map_outlined,
                        tooltip: _overview ? s.navRecenter : s.navOverview,
                        onTap: _toggleOverview,
                      ),
                      // Recenter appears only once the driver has taken
                      // the camera.
                      if (!_follow && !_overview) ...[
                        const SizedBox(height: 10),
                        _roundMapBtn(
                          icon: Icons.my_location_rounded,
                          tooltip: s.navRecenter,
                          onTap: _recenter,
                        ),
                      ],
                    ],
                  ),
                ),
                if (widget.stage == 'waiting_rider' ||
                    widget.stage == 'start_ride')
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom:
                        lift + (_stageControlVisible ? _stageControlHeight + 10 : 0),
                    child: _buildWaitBar(s),
                  ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: lift,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 420),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: ScaleTransition(
                        scale: Tween<double>(begin: 0.92, end: 1.0)
                            .animate(anim),
                        child: child,
                      ),
                    ),
                    child: KeyedSubtree(
                      key: ValueKey('nav-stage-${widget.stage}'),
                      child: _buildStageControl(s),
                    ),
                  ),
                ),
              ],
            );
          },
        ),

        // ── Rider stale-fix label, next to the halo ──
        if (_riderLabelPos != null && widget.toPickup)
          Positioned(
            left: _riderLabelPos!.dx + 26,
            top: _riderLabelPos!.dy - 10,
            child: IgnorePointer(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: _navyBar.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  s.navRiderLocationStale(_riderStaleSecs),
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),

        // ── Rider sheet ──
        DraggableScrollableSheet(
          controller: _sheetCtrl,
          initialChildSize: 0.20,
          minChildSize: 0.12,
          maxChildSize: 0.72,
          builder: (ctx, scrollCtrl) => Container(
            decoration: BoxDecoration(
              color: neuBase,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.06), width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 24,
                  offset: const Offset(0, -6),
                ),
              ],
            ),
            child: _buildSheet(s, scrollCtrl),
          ),
        ),
      ],
    );
  }

  Widget _buildManeuverBar(S s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: _navyBar.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _gold.withValues(alpha: 0.25), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(_maneuverIcon(_maneuverType, _maneuverModifier),
              color: Colors.white, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _streetLabel.isEmpty ? s.navFollowRoute : _streetLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _maneuverDistLabel.isEmpty
                      ? s.navFollowRoute
                      : _maneuverDistLabel,
                  style: const TextStyle(
                    color: _gold,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_thenLabel.isNotEmpty)
                  Text(
                    _thenLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),
          // Way back to the trip sheet — navigation never traps the driver.
          Tooltip(
            message: s.navExit,
            child: GestureDetector(
              onTap: () {
                HapticService.lightImpact();
                widget.onExit();
              },
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.close_rounded,
                    color: Colors.white70, size: 18),
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _maneuverIcon(String type, String modifier) {
    if (type == 'arrive') return Icons.flag_rounded;
    if (type == 'roundabout' || type == 'rotary') {
      return Icons.roundabout_left_rounded;
    }
    if (type == 'merge') return Icons.merge_rounded;
    if (type == 'fork') {
      return modifier.contains('left')
          ? Icons.fork_left_rounded
          : Icons.fork_right_rounded;
    }
    if (type == 'on ramp' || type == 'off ramp') {
      return modifier.contains('left')
          ? Icons.ramp_left_rounded
          : Icons.ramp_right_rounded;
    }
    if (modifier.contains('uturn')) return Icons.u_turn_left_rounded;
    if (modifier.contains('sharp left')) return Icons.turn_sharp_left_rounded;
    if (modifier.contains('sharp right')) {
      return Icons.turn_sharp_right_rounded;
    }
    if (modifier.contains('slight left')) {
      return Icons.turn_slight_left_rounded;
    }
    if (modifier.contains('slight right')) {
      return Icons.turn_slight_right_rounded;
    }
    if (modifier.contains('left')) return Icons.turn_left_rounded;
    if (modifier.contains('right')) return Icons.turn_right_rounded;
    return Icons.straight_rounded;
  }

  Widget _buildSpeedBox() {
    final mph = (_speedMps * 2.23694).round();
    return Container(
      width: 64,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: _navyBar.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$mph',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'mph',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _roundMapBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: _navyBar.withValues(alpha: 0.92),
            shape: BoxShape.circle,
            border:
                Border.all(color: _gold.withValues(alpha: 0.35), width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Icon(icon, color: _gold, size: 22),
        ),
      ),
    );
  }

  Widget _buildWaitBar(S s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: _navyBar.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _gold.withValues(alpha: 0.25)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            s.navWaitFor(_waitClock),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          // The divider IS the timer: it drains to nothing over 5 minutes.
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: _waitRemainFrac.clamp(0.0, 1.0),
                child: Container(height: 3, color: _gold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStageControl(S s) {
    switch (widget.stage) {
      case 'arrived':
        return SizedBox(
          width: double.infinity,
          height: 62,
          child: ElevatedButton(
            onPressed: () {
              HapticService.heavyImpact();
              widget.onArrived();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(31)),
              elevation: 0,
            ),
            child: Text(
              s.arrived,
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
          ),
        );
      case 'start_ride':
        return _buildSlideBar(s.navSlideToPickUp);
      case 'finish':
        return _buildSlideBar(s.navSlideToFinish);
      default:
        // arrived_locked / finish_locked / driving stages: nothing to press.
        return const SizedBox.shrink();
    }
  }

  /// Same slide mechanic as the accept screen's `_buildSlideArrived`: fill,
  /// label that fades under the thumb, gold thumb that commits at 88%.
  Widget _buildSlideBar(String label) {
    const height = 62.0;
    const thumbW = 62.0;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111318),
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(color: _gold.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final trackW = constraints.maxWidth;
          final maxDrag = trackW - thumbW - 4;
          return SizedBox(
            height: height,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: (_slideVal * maxDrag + thumbW)
                      .clamp(thumbW.toDouble(), trackW),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          _gold.withValues(alpha: 0.45),
                          _gold.withValues(alpha: 0.10),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(height / 2),
                    ),
                  ),
                ),
                Center(
                  child: AnimatedOpacity(
                    opacity: 1.0 - _slideVal,
                    duration: const Duration(milliseconds: 100),
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 2 + _slideVal * maxDrag,
                  top: 3,
                  bottom: 3,
                  child: GestureDetector(
                    onHorizontalDragUpdate: (d) =>
                        _onSlideUpdate(d.delta.dx, maxDrag),
                    onHorizontalDragEnd: (_) {
                      if (!_slideDone) setState(() => _slideVal = 0);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 80),
                      width: thumbW - 4,
                      decoration: BoxDecoration(
                        color: _slideDone
                            ? _gold.withValues(alpha: 0.8)
                            : _gold,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.5),
                            blurRadius: 12,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      // The thumb's arrow points the way the slide goes.
                      child: Icon(
                        _slideDone
                            ? Icons.check_rounded
                            : Icons.chevron_right_rounded,
                        color: Colors.black,
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ─────────────────────────────────────────────
  //  Sheet
  // ─────────────────────────────────────────────

  Widget _buildSheet(S s, ScrollController scrollCtrl) {
    final mins = (_remainSecs / 60).ceil();
    final distLabel = _fmtDist(_remainMeters, s);
    final destName =
        widget.toPickup ? widget.pickupAddress : widget.dropoffAddress;
    return ListView(
      controller: scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Center(
          child: Container(
            margin: const EdgeInsets.only(top: 10, bottom: 10),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        // Collapsed face: rider, "9 min · 4.1 mi", destination, chat/call.
        Row(
          children: [
            VerifiedAvatar(
              photoUrl: widget.riderPhotoUrl,
              radius: 24,
              fallbackName: widget.riderName,
              uid: widget.riderId?.toString(),
              role: 'rider',
              isVerified: true,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _remainSecs > 0 ? '$mins min · $distLabel' : distLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    destName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            _sheetCircleBtn(
                Icons.message_rounded, s.messageAction, widget.onOpenChat),
            const SizedBox(width: 8),
            _sheetCircleBtn(Icons.phone_rounded, s.callAction, widget.onCall),
          ],
        ),
        const SizedBox(height: 16),
        // Expanded content (visible once the sheet is dragged up).
        _sheetAddressRow(
            Icons.place_rounded, s.pickupLabel, widget.pickupAddress),
        const SizedBox(height: 10),
        _sheetAddressRow(
            Icons.flag_rounded, s.dropOffLabel, widget.dropoffAddress),
        if (widget.passengerInstructions.isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: neuBox(radius: 14),
            child: Text(
              widget.passengerInstructions,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 13, height: 1.4),
            ),
          ),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            Text(
              s.navEstimatedEarnings,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const Spacer(),
            Text(
              '\$${widget.fare.toStringAsFixed(2)}',
              style: const TextStyle(
                color: _gold,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: () {
            HapticService.lightImpact();
            widget.onSupport();
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border:
                  Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.report_problem_rounded,
                    color: Colors.white54, size: 17),
                const SizedBox(width: 8),
                Text(
                  s.navReportProblem,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Room for the stage control floating over the sheet's top edge.
        const SizedBox(height: _stageControlHeight + 76),
      ],
    );
  }

  Widget _sheetCircleBtn(IconData icon, String label, VoidCallback onTap) {
    return Tooltip(
      message: label,
      child: GestureDetector(
        onTap: () {
          HapticService.lightImpact();
          onTap();
        },
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: neuSurface,
            shape: BoxShape.circle,
            border:
                Border.all(color: _gold.withValues(alpha: 0.3), width: 1),
          ),
          child: Icon(icon, color: _gold, size: 19),
        ),
      ),
    );
  }

  Widget _sheetAddressRow(IconData icon, String label, String address) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: _gold, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                address,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
