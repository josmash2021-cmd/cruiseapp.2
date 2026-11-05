part of 'driver_online_screen.dart';

// ══════════════════════════════════════════════════════════════
//  HEAT ZONES — riders building a trip (owner 2026-11-05)
//
//  • The clouds: a native heatmap layer on the map FLOOR (under the roads
//    and labels), fed live by RiderHeatWatcher. Every change eases over
//    1.2 s (HeatFader) — a new cloud grows from nothing, nothing jumps.
//  • The flames: one gold flame per cloud, a Flutter overlay glued per
//    camera frame like the callouts; it fades with its cloud.
//  • A new flame eases the follow camera out once so it is on screen
//    ("cuando salgan llamas se centra solo el mapa mostrando las zonas").
//  • Tap a flame (online or offline): the camera frames the drive there
//    over the card "Zona con pasajeros · place · mi · min"; "Navegar a la
//    zona" opens the app's navigation to a street address in it.
// ══════════════════════════════════════════════════════════════

/// Everything the heat keeps between frames — one field on the State.
class _HeatState {
  final RiderHeatLayer layer = RiderHeatLayer();
  final HeatFader fader = HeatFader();
  final GradientRouteLine routeLine = GradientRouteLine(
    sourceId: 'heat-route-src',
    layerId: 'heat-route-line',
    width: 6.5,
  );

  /// The cells as the server last sent them.
  List<HeatCell> cells = const [];
  List<HeatZone> zones = const [];

  /// Flames whose cloud left, fading out, by zone key.
  final Map<int, HeatZone> leaving = {};
  int _keys = 0;
  int nextKey() => ++_keys;

  /// The layer sits under this road layer (looked up once per surface).
  String? belowId;
  bool belowLooked = false;
  double? latDeg;
  Timer? fadeTimer;
  VoidCallback? listener;

  // ── The card ──
  HeatZone? open;
  int openSeq = 0;
  String? subtitle;
  LatLng? dest;
  String place = '';

  void forgetSurface() {
    layer.forget();
    routeLine.forget();
    belowId = null;
    belowLooked = false;
  }

  void dispose() {
    fadeTimer?.cancel();
    fadeTimer = null;
  }
}

/// Only zones this close are worth moving the camera for.
const double _kHeatRevealMaxM = 30000;

/// Room the card takes at the bottom when the camera frames the drive.
const double _kHeatCardRoom = 210;

extension _DriverOnlineHeat on _DriverOnlineScreenState {
  /// Flames and the card only over a plain, rendered map (online or
  /// offline): no offer, no preview, no celebration, no trip phase.
  bool get _heatWanted =>
      !kIsWeb &&
      _phase == _Phase.searching &&
      _pendingOffers.isEmpty &&
      _previewingOffer == null &&
      _acceptedOverlay == null &&
      _mapMounted &&
      _mapStyleLoaded &&
      _firstRenderDone;

  bool get _heatCardShown => _heat.open != null && _heatWanted;

  void _heatAttach() {
    if (kIsWeb) return;
    final l = _heat.listener = _onHeatCells;
    RiderHeatWatcher.cells.addListener(l);
    RiderHeatWatcher.acquire();
    if (RiderHeatWatcher.cells.value.isNotEmpty) _onHeatCells();
  }

  void _heatDetach() {
    final l = _heat.listener;
    if (l != null) RiderHeatWatcher.cells.removeListener(l);
    _heat.listener = null;
    RiderHeatWatcher.release();
    _heat.dispose();
  }

  /// New cells from the server: fade the clouds there, re-key the flames,
  /// and bring any NEW flame into view.
  void _onHeatCells() {
    if (!mounted) return;
    final cells = RiderHeatWatcher.cells.value;
    _heat.cells = cells;
    _heat.fader.setTarget(cells, DateTime.now().millisecondsSinceEpoch);
    final before = _heat.zones;
    final next = heatZonesFrom(cells, previous: before, nextKey: _heat.nextKey);
    final nextKeys = {for (final z in next) z.key};
    final beforeKeys = {for (final z in before) z.key};
    for (final z in before) {
      if (nextKeys.contains(z.key)) continue;
      _heat.leaving[z.key] = z;
      Timer(const Duration(milliseconds: kHeatFadeMs + 100), () {
        if (!mounted) return;
        _heat.leaving.remove(z.key);
        _markerFrame.value++;
      });
    }
    for (final k in nextKeys) {
      _heat.leaving.remove(k);
    }
    _heat.zones = next;
    _markerFrame.value++;
    final open = _heat.open;
    if (open != null && !nextKeys.contains(open.key)) _closeHeatZone();
    _heatRevealNew([
      for (final z in next)
        if (!beforeKeys.contains(z.key)) z,
    ]);
    // Every cloud gone and nothing on the board: back to the working zoom.
    if (next.isEmpty &&
        _availableTrips.isEmpty &&
        _cameraFollowing &&
        _searchFollowZoom < kSearchFollowZoom) {
      _easeSearchFollowZoom(kSearchFollowZoom, ms: 900);
    }
    _heatStartFade();
  }

  /// Push faded frames to the layer while anything is still easing.
  void _heatStartFade() {
    if (_heat.fadeTimer != null) return;
    _heatPushFrame();
    _heat.fadeTimer =
        Timer.periodic(const Duration(milliseconds: 33), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      _heatPushFrame();
      if (!_heat.fader.animating(now)) {
        t.cancel();
        _heat.fadeTimer = null;
        _heatPushFrame(); // the settled frame
      }
    });
  }

  void _heatPushFrame() {
    final map = _map;
    if (map == null || kIsWeb || !_mapStyleLoaded || !_firstRenderDone) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final cells = _heat.fader.at(now);
    final lat = _heat.latDeg ??= _pos?.latitude ??
        (cells.isNotEmpty ? cells.first.lat : null);
    if (lat == null) return;
    if (!_heat.belowLooked) {
      _heat.belowLooked = true;
      unawaited(_zoneRoadAnchor(map).then((id) {
        _heat.belowId = id;
        if (mounted) _heatPushFrame();
      }));
      return;
    }
    unawaited(
        _heat.layer.set(map, cells, belowLayerId: _heat.belowId, latDeg: lat));
  }

  /// Every map idle beat: (re)build the layer after a style load or a
  /// surface rebirth, and drop a drive line that no longer has its card.
  void _heatSync() {
    if (kIsWeb) return;
    if (_heat.fader.isEmpty && _heat.cells.isEmpty) return;
    if (_heat.fadeTimer == null) _heatPushFrame();
    if (_heat.open != null && !_heatWanted) _closeHeatZone(recenter: false);
  }

  /// Ease the follow camera out once so new flames are on screen — the
  /// arrow stays centred and follow stays on, like a new trip on the board.
  /// A driver who panned the map away keeps their view.
  void _heatRevealNew(List<HeatZone> fresh) {
    final pos = _pos;
    final size = _onlineMapSize;
    if (fresh.isEmpty ||
        pos == null ||
        size == null ||
        !_heatWanted ||
        !_cameraFollowing ||
        _heat.open != null ||
        _resvCardShown) {
      return;
    }
    var farthestM = 0.0;
    for (final z in fresh) {
      final m = _hav(pos, z.center) * 1000;
      if (m.isFinite && m <= _kHeatRevealMaxM && m > farthestM) farthestM = m;
    }
    if (farthestM <= 0) return;
    final z = boardRevealZoom(
        latDeg: pos.latitude, farthestM: farthestM, viewport: size);
    if (z < _searchFollowZoom - 0.05) _easeSearchFollowZoom(z, ms: 1400);
  }

  /// The flames, on their clouds. Tappable; the rest reaches the map.
  Widget _heatFlameOverlay() {
    if (kIsWeb) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: _markerFrame,
      builder: (context, _) {
        if (!_heatWanted) return const SizedBox.shrink();
        if (_heat.zones.isEmpty && _heat.leaving.isEmpty) {
          return const SizedBox.shrink();
        }
        final cam = _onlineCamState;
        final size = _onlineMapSize;
        if (cam == null || size == null) return const SizedBox.shrink();
        final c = cam.center.coordinates;
        final camCenter = LatLng(c.lat.toDouble(), c.lng.toDouble());
        final shift = _camPadShift(cam);
        final children = <Widget>[];
        void add(HeatZone z, bool visible) {
          final off = FlatMapProjection.screenOffsetHeading(
            target: z.center,
            cameraCenter: camCenter,
            zoom: cam.zoom,
            bearingDeg: cam.bearing,
            pitchDeg: cam.pitch,
            viewport: size,
          );
          if (off == null) return;
          final p = off + shift;
          if (!FlatMapProjection.isOnScreen(p, size,
              margin: _kCalloutCullMargin)) {
            return;
          }
          children.add(Positioned(
            // Keyed by cloud: the flame keeps its fade while the camera
            // moves and riders come and go.
            key: ValueKey('heat-flame-${z.key}'),
            left: p.dx - kHeatFlameTapSize / 2,
            top: p.dy - kHeatFlameTapSize / 2,
            child: HeatFlameMarker(
              visible: visible,
              onTap: () => _openHeatZone(z.key),
            ),
          ));
        }

        for (final z in _heat.leaving.values) {
          add(z, false);
        }
        for (final z in _heat.zones) {
          add(z, true);
        }
        if (children.isEmpty) return const SizedBox.shrink();
        return Stack(clipBehavior: Clip.none, children: children);
      },
    );
  }

  /// Tap a flame: the card at once, then the place, the drive and the
  /// framing as they come in.
  Future<void> _openHeatZone(int key) async {
    if (!mounted || !_heatWanted) return;
    HeatZone? zone;
    for (final z in _heat.zones) {
      if (z.key == key) zone = z;
    }
    if (zone == null) return;
    HapticService.lightImpact();
    final seq = ++_heat.openSeq;
    _setState(() {
      _heat.open = zone;
      _heat.subtitle = null;
      _heat.dest = null;
      _heat.place = '';
      _resvCardOpen = false;
      // The camera is ours while the card is up.
      _cameraFollowing = false;
    });
    final pos = _pos;
    unawaited(_heatFrame([if (pos != null) pos, zone.center]));
    final snap = await _heatSnapToStreet(zone.center);
    if (!mounted || seq != _heat.openSeq) return;
    final dest = snap?.$1 ?? zone.center;
    final place = snap?.$2 ?? '';
    var route = const <LatLng>[];
    double? miles;
    int? minutes;
    if (pos != null) {
      final r = await _fetchRouteWithMetrics(pos, dest);
      if (!mounted || seq != _heat.openSeq) return;
      route = r.pts;
      final d = r.distM;
      final t = r.durSec;
      if (d != null && d.isFinite) miles = d / 1609.344;
      if (t != null && t.isFinite) minutes = (t / 60).round();
    }
    _setState(() {
      _heat.dest = dest;
      _heat.place = place;
      _heat.subtitle = heatZoneSubtitle(place, miles, minutes);
    });
    final map = _map;
    if (route.length >= 2 && map != null) {
      await _heat.routeLine.set(map, route);
      if (!mounted || seq != _heat.openSeq) return;
      unawaited(_heatFrame(route));
    } else {
      unawaited(_heatFrame([if (pos != null) pos, dest]));
    }
  }

  /// Frame [points] above the card, flat and north-up.
  Future<void> _heatFrame(List<LatLng> points) async {
    final map = _map;
    final mq = MediaQuery.maybeOf(context);
    if (map == null || mq == null || points.isEmpty) return;
    final coords = <mapbox.Point>[
      for (final p in points)
        if (safePoint(p.longitude, p.latitude) != null)
          safePoint(p.longitude, p.latitude)!,
    ];
    if (coords.isEmpty) return;
    final seq = _heat.openSeq;
    try {
      final cam = await map.cameraForCoordinatesPadding(
        coords,
        mapbox.CameraOptions(pitch: 0, bearing: 0),
        mapbox.MbxEdgeInsets(
          top: mq.padding.top + 70,
          left: 48,
          bottom: _kHeatCardRoom + mq.padding.bottom,
          right: 48,
        ),
        null,
        null,
      );
      if ((cam.zoom ?? 15.5) > 15.5) cam.zoom = 15.5;
      if (!mounted || _heat.open == null || seq != _heat.openSeq) return;
      _camera(cam, animateMs: 900);
    } catch (e) {
      debugPrint('[RiderHeat] frame failed: $e');
    }
  }

  /// The X (or the cloud went away): card down, line off, camera back.
  void _closeHeatZone({bool recenter = true}) {
    if (!mounted) return;
    final wasOpen = _heat.open != null;
    _heat.openSeq++;
    final map = _map;
    if (map != null) {
      unawaited(_heat.routeLine.hide(map));
    } else {
      _heat.routeLine.forget();
    }
    if (!wasOpen) return;
    _setState(() {
      _heat.open = null;
      _heat.subtitle = null;
      _heat.dest = null;
    });
    if (recenter && _heatWanted) _recenterCamera();
  }

  /// "Navegar a la zona": the app's navigation, to the street address the
  /// cloud was snapped to. The card closes behind it.
  void _navigateToHeatZone() {
    final dest = _heat.dest;
    final pos = _pos;
    if (!mounted || dest == null || pos == null) return;
    final nav = Navigator.maybeOf(context);
    if (nav == null) return;
    HapticService.lightImpact();
    final place = _heat.place;
    _closeHeatZone(recenter: false);
    // The trip screen's slide (no iOS edge swipe dragging the navigation
    // away); back on the online map once its surface is mounted again.
    unawaited(nav
        .push(ZoneNavScreen.route(
          destination: dest,
          zoneName: place,
          initialDriverPos: pos,
        ))
        .then((_) async {
      if (!mounted) return;
      await _remountMapSurface();
      if (mounted && _heatWanted) _recenterCamera();
    }));
  }

  /// A street address inside the cloud (Mapbox reverse geocoding,
  /// addresses only — so never a highway lane) and the place's name
  /// (neighbourhood, else town). Null when nothing usable came back.
  Future<(LatLng, String)?> _heatSnapToStreet(LatLng at) async {
    try {
      final lang = S.of(context).locale.languageCode;
      final url = Uri.parse(
        'https://api.mapbox.com/geocoding/v5/mapbox.places/'
        '${at.longitude},${at.latitude}.json'
        '?types=address&limit=1&language=$lang'
        '&access_token=${MapboxConfig.accessToken}',
      );
      final res = await http.get(url).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final features = (jsonDecode(res.body) as Map)['features'] as List?;
      if (features == null || features.isEmpty) return null;
      final f = features.first as Map;
      final center = f['center'] as List?;
      String? byKind(String kind) {
        for (final c in (f['context'] as List?) ?? const []) {
          if (c is Map && (c['id'] ?? '').toString().startsWith('$kind.')) {
            final t = (c['text'] ?? '').toString().trim();
            if (t.isNotEmpty) return t;
          }
        }
        return null;
      }

      final place =
          byKind('neighborhood') ?? byKind('locality') ?? byKind('place') ?? '';
      LatLng dest = at;
      if (center != null && center.length >= 2) {
        final lng = (center[0] as num?)?.toDouble();
        final lat = (center[1] as num?)?.toDouble();
        if (lat != null && lng != null && isValidLatLng(lat, lng)) {
          final p = LatLng(lat, lng);
          // An address far out of the cloud (open country) is no help:
          // drive to the cloud itself.
          if (_hav(at, p) * 1000 <= kHeatZoneSameM) dest = p;
        }
      }
      return (dest, place);
    } catch (e) {
      debugPrint('[RiderHeat] snap failed: $e');
      return null;
    }
  }

  /// The card, slid in from the bottom in the sheet's place.
  Widget _heatCardLayer() {
    final shown = _heatCardShown;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !shown,
        child: AnimatedSlide(
          offset: shown ? Offset.zero : const Offset(0, 1),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          child: AnimatedOpacity(
            opacity: shown ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 300),
            child: HeatZoneCard(
              subtitle: _heat.subtitle,
              bottomInset: MediaQuery.paddingOf(context).bottom,
              onClose: _closeHeatZone,
              onNavigate: _heat.dest == null ? null : _navigateToHeatZone,
            ),
          ),
        ),
      ),
    );
  }
}
