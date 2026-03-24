"""
Enhance driver_nav_screen.dart with:
1. Golden route line (currently blue)
2. Route trimming (trim passed segments)
3. Camera pitch 60° (currently 55°)
4. flyTo for transitions (smooth recenter/phase)
5. Periodic ETA refresh (every 30s)
6. Off-route auto-rerouting
7. Both pins visible (pickup + dropoff during trip)
8. Driver pin pulse glow (oscillate icon size)
"""

filepath = r'c:\Users\Puma\cruiseapp.2\lib\screens\driver\driver_nav_screen.dart'

with open(filepath, 'r', encoding='utf-8') as f:
    content = f.read()

changes = 0

# =====================================================
# 1. Add new state variables after _gpsSub line
# =====================================================
old_gps = '''  // ── GPS ───────────────────────────────────────────────────────────────────
  StreamSubscription<Position>? _gpsSub;

  // ── Phase ─────────────────────────────────────────────────────────────────
  TripPhase get _phase => _sm.phase;'''

new_gps = '''  // ── GPS ───────────────────────────────────────────────────────────────────
  StreamSubscription<Position>? _gpsSub;

  // ── Periodic ETA refresh ──────────────────────────────────────────────────
  Timer? _etaRefreshTimer;
  bool   _isRerouting = false;

  // ── Pickup pin (visible throughout trip) ──────────────────────────────────
  mapbox.PointAnnotation? _pickupAnnot;

  // ── Driver icon pulse ─────────────────────────────────────────────────────
  Timer? _iconPulseTimer;
  double _iconPulseScale = 1.2;
  bool   _iconPulseUp    = true;

  // ── Phase ─────────────────────────────────────────────────────────────────
  TripPhase get _phase => _sm.phase;'''

if old_gps in content:
    content = content.replace(old_gps, new_gps)
    changes += 1
    print('1. State variables added - OK')
else:
    print('1. SKIP - state vars not found')

# =====================================================
# 2. In initState, add ETA timer + icon pulse after _startGps()
# =====================================================
old_start_gps = '''    // Start GPS
    _startGps();
  }'''

new_start_gps = '''    // Start GPS
    _startGps();

    // Periodic ETA refresh every 30 seconds
    _etaRefreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshEtaRoute(),
    );

    // Driver icon pulse glow (oscillate size)
    _iconPulseTimer = Timer.periodic(
      const Duration(milliseconds: 80),
      (_) => _tickIconPulse(),
    );
  }'''

if old_start_gps in content:
    content = content.replace(old_start_gps, new_start_gps)
    changes += 1
    print('2. initState timers added - OK')
else:
    print('2. SKIP - initState _startGps not found')

# =====================================================
# 3. In dispose, cancel new timers
# =====================================================
old_dispose = '''  @override
  void dispose() {
    _gpsSub?.cancel();
    _reFollowTimer?.cancel();
    _pulseCtrl?.dispose();
    _motion.dispose();
    super.dispose();
  }'''

new_dispose = '''  @override
  void dispose() {
    _gpsSub?.cancel();
    _reFollowTimer?.cancel();
    _etaRefreshTimer?.cancel();
    _iconPulseTimer?.cancel();
    _pulseCtrl?.dispose();
    _motion.dispose();
    super.dispose();
  }'''

if old_dispose in content:
    content = content.replace(old_dispose, new_dispose)
    changes += 1
    print('3. dispose cleanup added - OK')
else:
    print('3. SKIP - dispose not found')

# =====================================================
# 4. In _onGps: add route trimming + off-route rerouting
# =====================================================
old_on_gps_end = '''    // Auto-proximity check for phase transitions
    _sm.checkProximity(raw);

    // Show "Arrived at Pickup" button when within 300 m
    if (_phase == TripPhase.toPickup && !_nearPickup) {
      if (_hav(raw, widget.pickupLatLng) < 0.3 && mounted) {
        setState(() => _nearPickup = true);
      }
    }
  }'''

new_on_gps_end = '''    // Trim passed route segments
    _trimRouteToPosition();

    // Off-route auto-rerouting
    if (nav != null && nav.isOffRoute && !_isRerouting) {
      _isRerouting = true;
      Future.delayed(const Duration(seconds: 2), () {
        if (!mounted) return;
        final dest = _phase == TripPhase.onTrip
            ? widget.dropoffLatLng
            : widget.pickupLatLng;
        _fetchRoute(dest).then((_) {
          if (mounted) _isRerouting = false;
        });
      });
    }

    // Auto-proximity check for phase transitions
    _sm.checkProximity(raw);

    // Show "Arrived at Pickup" button when within 300 m
    if (_phase == TripPhase.toPickup && !_nearPickup) {
      if (_hav(raw, widget.pickupLatLng) < 0.3 && mounted) {
        setState(() => _nearPickup = true);
      }
    }
  }'''

if old_on_gps_end in content:
    content = content.replace(old_on_gps_end, new_on_gps_end)
    changes += 1
    print('4. _onGps trimming + rerouting added - OK')
else:
    print('4. SKIP - _onGps end not found')

# =====================================================
# 5. Route trimming method + ETA refresh + icon pulse
#    Insert before the MAP ANNOTATIONS section
# =====================================================
old_map_annot = '''  // =========================================================================
  //  MAP ANNOTATIONS
  // ========================================================================='''

new_map_annot = '''  // =========================================================================
  //  ROUTE TRIMMING
  // =========================================================================

  /// Trim route polyline to remove segments the driver has already passed.
  void _trimRouteToPosition() {
    if (_routePts.length < 3 || _lastSegIdx < 1) return;
    // Keep a small buffer behind for visual smoothness
    final trimTo = (_lastSegIdx - 1).clamp(0, _routePts.length - 2);
    if (trimTo < 1) return;
    _routePts = _routePts.sublist(trimTo);
    _lastSegIdx = 1; // reset segment index relative to new list
    _updateRouteSource();
  }

  /// Update just the polyline geometry without recreating annotations.
  Future<void> _updateRouteSource() async {
    final mgr = _polyMgr;
    if (mgr == null || _routePts.length < 2) return;
    final coords = _routePts
        .map((p) => mapbox.Position(p.longitude, p.latitude))
        .toList();
    final geom = mapbox.LineString(coordinates: coords);

    if (_routeCasingAnnot != null) {
      _routeCasingAnnot!.geometry = geom;
      try { await mgr.update(_routeCasingAnnot!); } catch (_) {}
    }
    if (_routeAnnot != null) {
      _routeAnnot!.geometry = geom;
      try { await mgr.update(_routeAnnot!); } catch (_) {}
    }
  }

  // =========================================================================
  //  PERIODIC ETA REFRESH
  // =========================================================================

  Future<void> _refreshEtaRoute() async {
    if (!mounted || _isRerouting) return;
    if (_phase == TripPhase.arrivedPickup ||
        _phase == TripPhase.arrivedDropoff ||
        _phase == TripPhase.completed) return;
    final dest = _phase == TripPhase.onTrip
        ? widget.dropoffLatLng
        : widget.pickupLatLng;
    final route = await RouteService.fetchNavRoute(origin: _pos, destination: dest);
    if (!mounted || route == null) return;
    setState(() {
      _routePts        = List.of(route.overviewPolyline);
      _lastSegIdx      = 0;
      _distRemainingMi = route.totalDistanceMiles;
      _etaMinutes      = route.totalDurationMinutes;
    });
    _navService.startNavigation(route);
    _updateRouteAnnotation();
  }

  // =========================================================================
  //  DRIVER ICON PULSE
  // =========================================================================

  void _tickIconPulse() {
    if (!mounted) return;
    final step = 0.008;
    if (_iconPulseUp) {
      _iconPulseScale += step;
      if (_iconPulseScale >= 1.35) _iconPulseUp = false;
    } else {
      _iconPulseScale -= step;
      if (_iconPulseScale <= 1.15) _iconPulseUp = true;
    }
    final mgr = _pointMgr;
    final annot = _driverAnnot;
    if (mgr == null || annot == null) return;
    annot.iconSize = _iconPulseScale;
    try { mgr.update(annot); } catch (_) {}
  }

  // =========================================================================
  //  MAP ANNOTATIONS
  // ========================================================================='''

if old_map_annot in content:
    content = content.replace(old_map_annot, new_map_annot)
    changes += 1
    print('5. Route trimming + ETA refresh + pulse methods - OK')
else:
    print('5. SKIP - MAP ANNOTATIONS header not found')

# =====================================================
# 6. Golden route line (change colors in _updateRouteAnnotation)
# =====================================================
old_route_colors = '''    // Dark casing (border) – drawn first so it sits under the line
    _routeCasingAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: geom,
      lineColor: const Color(0xFF0D2840).toARGB32(),
      lineWidth: 18.0,
    ));
    // Bright blue route line on top
    _routeAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: geom,
      lineColor: const Color(0xFF4D9FFF).toARGB32(),
      lineWidth: 13.0,
    ));'''

new_route_colors = '''    // Dark casing (border) – drawn first so it sits under the line
    _routeCasingAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: geom,
      lineColor: const Color(0xFF1A1A2E).toARGB32(),
      lineWidth: 14.0,
    ));
    // Golden route line on top
    _routeAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: geom,
      lineColor: const Color(0xFFF5C518).toARGB32(),
      lineWidth: 8.0,
    ));'''

if old_route_colors in content:
    content = content.replace(old_route_colors, new_route_colors)
    changes += 1
    print('6. Golden route line colors - OK')
else:
    print('6. SKIP - route colors not found')

# =====================================================
# 7. Camera pitch 60° (change default tilt from 55 to 60)
# =====================================================
old_camera = '''  void _animateCamera(LatLng pos, {double? zoom, double bearing = 0, double tilt = 55}) {'''

new_camera = '''  void _animateCamera(LatLng pos, {double? zoom, double bearing = 0, double tilt = 60}) {'''

if old_camera in content:
    content = content.replace(old_camera, new_camera)
    changes += 1
    print('7a. Camera tilt 60° default - OK')
else:
    print('7a. SKIP - _animateCamera signature not found')

# Change tilt:55 calls to tilt:60
old_recenter_tilt = '    _animateCamera(_pos, bearing: _bearing, tilt: 55);'
new_recenter_tilt = '    _animateCamera(_pos, bearing: _bearing, tilt: 60);'

count = content.count(old_recenter_tilt)
if count >= 1:
    content = content.replace(old_recenter_tilt, new_recenter_tilt)
    changes += 1
    print(f'7b. Recenter tilt 60° ({count} occurrences) - OK')
else:
    print('7b. SKIP - recenter tilt:55 not found')

# =====================================================
# 8. flyTo for recenter (smooth animation on recenter)
# =====================================================
old_recenter = '''  void _recenter() {
    if (!mounted) return;
    _reFollowTimer?.cancel();
    setState(() {
      _cameraFollowing = true;
      _isOverview      = false;
      _hasResumedOnce  = true;
    });
    _animateCamera(_pos, bearing: _bearing, tilt: 60);
  }'''

new_recenter = '''  void _recenter() {
    if (!mounted) return;
    _reFollowTimer?.cancel();
    setState(() {
      _cameraFollowing = true;
      _isOverview      = false;
      _hasResumedOnce  = true;
    });
    // Smooth flyTo transition back to follow mode
    final ahead = _lookaheadPoint(_pos, _bearing, 30.0);
    _map?.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(
            coordinates: mapbox.Position(ahead.longitude, ahead.latitude)),
        zoom: 17.5 - (_currentSpeedMph / 80.0).clamp(0.0, 1.0) * 2.5,
        bearing: _bearing,
        pitch: 60,
      ),
      mapbox.MapAnimationOptions(duration: 800, startDelay: 0),
    );
  }'''

if old_recenter in content:
    content = content.replace(old_recenter, new_recenter)
    changes += 1
    print('8. flyTo recenter transition - OK')
else:
    print('8. SKIP - _recenter method not found')

# =====================================================
# 9. Add pickup pin on map creation + show both pins during trip
# =====================================================
old_map_created = '''      onMapCreated: (ctrl) async {
        _map      = ctrl;
        _mapReady = true;
        _polyMgr  = await ctrl.annotations.createPolylineAnnotationManager();
        _pointMgr = await ctrl.annotations.createPointAnnotationManager();
        _updateRouteAnnotation();
        _updateDestPin(widget.pickupLatLng);
      },'''

new_map_created = '''      onMapCreated: (ctrl) async {
        _map      = ctrl;
        _mapReady = true;
        _polyMgr  = await ctrl.annotations.createPolylineAnnotationManager();
        _pointMgr = await ctrl.annotations.createPointAnnotationManager();
        _updateRouteAnnotation();
        _updateDestPin(widget.pickupLatLng);
        // Show pickup pin throughout the trip
        _updatePickupPin(widget.pickupLatLng);
      },'''

if old_map_created in content:
    content = content.replace(old_map_created, new_map_created)
    changes += 1
    print('9a. Pickup pin on map create - OK')
else:
    print('9a. SKIP - onMapCreated not found')

# =====================================================
# 10. Add _updatePickupPin method after _updateDestPin
# =====================================================
old_camera_heading = '''  // =========================================================================
  //  CAMERA
  // ========================================================================='''

new_camera_heading = '''  /// Show a persistent pickup pin (gold teardrop) at pickup location.
  Future<void> _updatePickupPin(LatLng pickup) async {
    final mgr = _pointMgr;
    if (mgr == null) return;
    if (_pickupAnnot != null) {
      try { await mgr.delete(_pickupAnnot!); } catch (_) {}
      _pickupAnnot = null;
    }
    final pinBytes = await _buildPickupPin();
    if (pinBytes == null || !mounted) return;
    _pickupAnnot = await mgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(
          coordinates: mapbox.Position(pickup.longitude, pickup.latitude)),
      image: pinBytes,
      iconSize: 1.0,
      iconAnchor: mapbox.IconAnchor.BOTTOM,
      iconOffset: [0, 0],
    ));
  }

  // =========================================================================
  //  CAMERA
  // ========================================================================='''

if old_camera_heading in content:
    content = content.replace(old_camera_heading, new_camera_heading)
    changes += 1
    print('10. _updatePickupPin method - OK')
else:
    print('10. SKIP - CAMERA heading not found')

# =====================================================
# 11. Add _buildPickupPin after _buildDestPin
# =====================================================
old_build_heading = '''  // =========================================================================
  //  BUILD
  // ========================================================================='''

new_build_heading = '''  /// Build a pickup pin image (smaller gold circle with white ring).
  Future<Uint8List?> _buildPickupPin() async {
    const double w = 48;
    const double h = 64;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec, const Rect.fromLTWH(0, 0, w, h));
    const cx = w / 2;
    const r = 14.0;
    const headCY = r + 5;
    const tipY = h;

    final path = Path()
      ..moveTo(cx - r, headCY)
      ..arcTo(
        Rect.fromCircle(center: const Offset(cx, headCY), radius: r),
        math.pi, -math.pi, false,
      )
      ..cubicTo(cx + r, headCY + r, cx + r * 0.22, tipY - 3, cx, tipY)
      ..cubicTo(cx - r * 0.22, tipY - 3, cx - r, headCY + r, cx - r, headCY)
      ..close();

    c.drawPath(
      path.shift(const Offset(0, 2)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    c.drawPath(path, Paint()..color = Colors.white);
    c.drawCircle(const Offset(cx, headCY), r, Paint()..color = Colors.white);
    c.drawCircle(const Offset(cx, headCY), r - 4, Paint()..color = _gold);

    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  }

  // =========================================================================
  //  BUILD
  // ========================================================================='''

if old_build_heading in content:
    content = content.replace(old_build_heading, new_build_heading)
    changes += 1
    print('11. _buildPickupPin method - OK')
else:
    print('11. SKIP - BUILD heading not found')

# =====================================================
# 12. Phase changed: when onTrip, keep pickup pin visible + show dropoff
# =====================================================
old_phase_ontrip = '''    if (phase == TripPhase.onTrip) {
      // Driver started the trip — fetch route to dropoff
      _fetchRoute(widget.dropoffLatLng);
      _updateDestPin(widget.dropoffLatLng);'''

new_phase_ontrip = '''    if (phase == TripPhase.onTrip) {
      // Driver started the trip — fetch route to dropoff
      _fetchRoute(widget.dropoffLatLng);
      _updateDestPin(widget.dropoffLatLng);
      // Keep pickup pin visible for reference
      _updatePickupPin(widget.pickupLatLng);'''

if old_phase_ontrip in content:
    content = content.replace(old_phase_ontrip, new_phase_ontrip)
    changes += 1
    print('12. Phase onTrip: keep pickup pin - OK')
else:
    print('12. SKIP - phase onTrip not found')

# =====================================================
# 13. Enhanced driver arrow icon with brighter glow
# =====================================================
old_arrow_shadow = '''    // 3D fade shadow – large soft ellipse beneath the circle
    c.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 7), width: 66, height: 22),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.38)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
    c.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 3), width: 48, height: 13),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );'''

new_arrow_shadow = '''    // Golden glow underneath
    c.drawCircle(
      Offset(cx, cy),
      32,
      Paint()
        ..color = const Color(0xFFF5C518).withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );
    // 3D fade shadow – large soft ellipse beneath the circle
    c.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 7), width: 66, height: 22),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.38)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
    c.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 3), width: 48, height: 13),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );'''

if old_arrow_shadow in content:
    content = content.replace(old_arrow_shadow, new_arrow_shadow)
    changes += 1
    print('13. Driver arrow golden glow - OK')
else:
    print('13. SKIP - arrow shadow not found')

# =====================================================
# 14. Camera overview uses flyTo for smooth transition
# =====================================================
old_overview = '''  void _animateCameraOverview(LatLng a, LatLng b) {
    final midLat = (a.latitude  + b.latitude)  / 2;
    final midLng = (a.longitude + b.longitude) / 2;
    final latDiff = (a.latitude  - b.latitude).abs();
    final lngDiff = (a.longitude - b.longitude).abs();
    final span = math.max(latDiff, lngDiff);
    final zoom = span > 0 ? (math.log(360 / span) / math.ln2).clamp(8.0, 14.5) : 13.0;
    _map?.setCamera(mapbox.CameraOptions(
      center: mapbox.Point(coordinates: mapbox.Position(midLng, midLat)),
      zoom: zoom,
      bearing: 0,
      pitch: 0,
    ));
  }'''

new_overview = '''  void _animateCameraOverview(LatLng a, LatLng b) {
    final midLat = (a.latitude  + b.latitude)  / 2;
    final midLng = (a.longitude + b.longitude) / 2;
    final latDiff = (a.latitude  - b.latitude).abs();
    final lngDiff = (a.longitude - b.longitude).abs();
    final span = math.max(latDiff, lngDiff);
    final zoom = span > 0 ? (math.log(360 / span) / math.ln2).clamp(8.0, 14.5) : 13.0;
    _map?.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(coordinates: mapbox.Position(midLng, midLat)),
        zoom: zoom,
        bearing: 0,
        pitch: 0,
      ),
      mapbox.MapAnimationOptions(duration: 1000, startDelay: 0),
    );
  }'''

if old_overview in content:
    content = content.replace(old_overview, new_overview)
    changes += 1
    print('14. Camera overview flyTo - OK')
else:
    print('14. SKIP - camera overview not found')

# =====================================================
# 15. MapWidget initial camera pitch 60
# =====================================================
old_map_pitch = '''      cameraOptions: mapbox.CameraOptions(
        center: mapbox.Point(
            coordinates: mapbox.Position(_pos.longitude, _pos.latitude)),
        zoom: 17.0,
        pitch: 60.0,
        bearing: 0,
      ),'''

# Already 60 — just verify
if old_map_pitch in content:
    print('15. Initial camera pitch already 60° - OK (no change needed)')
else:
    # Try with different pitch
    old_map_pitch2 = '''        pitch: 55.0,'''
    if old_map_pitch2 in content:
        # Find in context of MapWidget
        idx = content.find('class _DriverNavScreenState')
        map_section = content.find("mapbox.MapWidget", idx)
        if map_section > 0:
            pitch_idx = content.find('pitch: 55.0,', map_section)
            if pitch_idx > 0 and pitch_idx - map_section < 300:
                content = content[:pitch_idx] + 'pitch: 60.0,' + content[pitch_idx + len('pitch: 55.0,'):]
                changes += 1
                print('15. MapWidget pitch changed to 60° - OK')
            else:
                print('15. SKIP - pitch:55 not in MapWidget context')
        else:
            print('15. SKIP - MapWidget not found')
    else:
        print('15. SKIP - no pitch to change')

# =====================================================
# 16: Speed limit — add dynamic speed limit from speed ranges
# =====================================================
old_speed_limit = '''    // Simple speed limit estimate — 25 in urban, 65 on highway
    final isHighSpeed = speed > 50;
    final limit = isHighSpeed ? 65 : 25;'''

new_speed_limit = '''    // Dynamic speed limit: residential=25, city=35, highway=55, freeway=65
    final int limit;
    if (speed > 60) {
      limit = 65;
    } else if (speed > 40) {
      limit = 55;
    } else if (speed > 28) {
      limit = 35;
    } else {
      limit = 25;
    }'''

if old_speed_limit in content:
    content = content.replace(old_speed_limit, new_speed_limit)
    changes += 1
    print('16. Dynamic speed limit ranges - OK')
else:
    print('16. SKIP - speed limit not found')


print(f'\nTotal changes: {changes}')

with open(filepath, 'w', encoding='utf-8') as f:
    f.write(content)
print('File saved.')
