part of 'driver_online_screen.dart';

// ══════════════════════════════════════════════════════════════
//  MAP — annotations, route preview, camera, pin builders
// ══════════════════════════════════════════════════════════════

extension _DriverOnlineMap on _DriverOnlineScreenState {

  /// Update the driver car / golden dot annotation on the Mapbox map.
  /// Uses a boolean lock to prevent overlapping async updates from the 60fps ticker.
  Future<void> _updateDriverAnnotation() async {
    if (!mounted || _annotUpdateBusy) return;
    _annotUpdateBusy = true;
    try {
      await _updateDriverAnnotationInner();
    } finally {
      _annotUpdateBusy = false;
    }
  }

  Future<void> _updateDriverAnnotationInner() async {
    if (!mounted) return;
    final pointMgr = _pointAnnotMgr;
    if (pointMgr == null) return;

    final isNav = _phase == _Phase.enRouteToPickup ||
        _phase == _Phase.inTrip ||
        _phase == _Phase.routeSummary;

    if (!isNav) {
      final dotBytes = _goldDot.currentBytes;
      if (dotBytes == null) return;
      // Remove car annotation if switching to gold dot
      if (_carAnnot != null) {
        try { await pointMgr.delete(_carAnnot!); } catch (_) {}
        _carAnnot = null;
      }
      if (_goldDotAnnot != null) {
        try {
          _goldDotAnnot!.geometry = mapbox.Point(coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude));
          _goldDotAnnot!.image = dotBytes;
          _goldDotAnnot!.iconSize = _dotPopScale;
          await pointMgr.update(_goldDotAnnot!);
        } catch (_) { _goldDotAnnot = null; }
      }
      if (_pos == null) return;
      if (_goldDotAnnot == null) {
        _goldDotAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),
          image: dotBytes,
          iconSize: _dotPopScale,
          iconAnchor: mapbox.IconAnchor.CENTER,
          iconOffset: [0, 0],
        ));
        // Trigger fade+pop on first creation
        if (!_dotPopDone) _animateDotPop();
      }
    } else if (isNav) {
      // Remove dot annotation if switching to car
      if (_goldDotAnnot != null) {
        try { await pointMgr.delete(_goldDotAnnot!); } catch (_) {}
        _goldDotAnnot = null;
      }
      // Use single rotated canvas car — sprites disabled (caused duplicate marker)
      final Uint8List? carBytes = _navCarIconBytes ?? _vehicleIconBytes ?? _arrowIconBytes;
      if (carBytes != null) {
        if (_carAnnot != null) {
          try {
            _carAnnot!.geometry = mapbox.Point(coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude));
            _carAnnot!.iconRotate = _heading;
            await pointMgr.update(_carAnnot!);
          } catch (_) { _carAnnot = null; }
        }
        if (_carAnnot == null) {
          _carAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
            geometry: mapbox.Point(coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),
            image: carBytes,
            iconSize: 1.2,
            iconRotate: _heading,
            iconAnchor: mapbox.IconAnchor.CENTER,
            iconOffset: [0, 0],
          ));
          // Car icon rotates relative to map, not camera
          try {
            await _map?.style.setStyleLayerProperty(
              pointMgr.id, 'icon-rotation-alignment', 'map');
          } catch (_) {}
        }
      }
    }
  }

  /// Fade + pop animation when the gold dot first appears.
  /// Scale: 0 → 1.15 (overshoot) → 1.0 (settle). ~350 ms total.
  Future<void> _animateDotPop() async {
    _dotPopDone = true;
    // Phase 1: scale 0 → 1.15 over ~200 ms (12 frames × 16 ms)
    const riseSteps = 12;
    for (int i = 1; i <= riseSteps; i++) {
      await Future.delayed(const Duration(milliseconds: 16));
      if (!mounted) return;
      _dotPopScale = (i / riseSteps) * 1.15;
      await _updateDriverAnnotation(); // await so frames don't pile up
    }
    // Phase 2: bounce back 1.15 → 1.0 over ~150 ms (9 frames × 16 ms)
    const bounceSteps = 9;
    for (int i = 1; i <= bounceSteps; i++) {
      await Future.delayed(const Duration(milliseconds: 16));
      if (!mounted) return;
      _dotPopScale = 1.15 - (0.15 * (i / bounceSteps));
      await _updateDriverAnnotation(); // await so frames don't pile up
    }
    _dotPopScale = 1.0;
    if (mounted) await _updateDriverAnnotation();
  }

  /// Snap a raw GPS coordinate to the nearest point on the active route polyline.
  /// Only snaps within 40 m — beyond that threshold the raw GPS is authoritative.
  LatLng _snapToRoute(LatLng raw) {
    if (_routePts.length < 2 ||
        (_phase != _Phase.enRouteToPickup && _phase != _Phase.inTrip)) {
      return raw;
    }
    double bestDist = double.infinity;
    LatLng best = raw;
    for (int i = 0; i < _routePts.length - 1; i++) {
      final candidate = _closestPointOnSegment(
        raw,
        _routePts[i],
        _routePts[i + 1],
      );
      final d = _hav(raw, candidate);
      if (d < bestDist) {
        bestDist = d;
        best = candidate;
      }
    }
    return bestDist <= 0.040 ? best : raw; // 40 m snap radius
  }

  /// Closest point on segment [a→b] to point [p] (flat lat/lng approximation).
  LatLng _closestPointOnSegment(LatLng p, LatLng a, LatLng b) {
    final dx = b.longitude - a.longitude;
    final dy = b.latitude - a.latitude;
    final len2 = dx * dx + dy * dy;
    if (len2 < 1e-12) return a;
    final t =
        ((p.longitude - a.longitude) * dx + (p.latitude - a.latitude) * dy) /
        len2;
    final tc = t.clamp(0.0, 1.0);
    return LatLng(a.latitude + tc * dy, a.longitude + tc * dx);
  }

  double _bearingBetween(LatLng a, LatLng b) {
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final aLat = a.latitude * math.pi / 180;
    final bLat = b.latitude * math.pi / 180;
    final x = math.sin(dLng) * math.cos(bLat);
    final y =
        math.cos(aLat) * math.sin(bLat) -
        math.sin(aLat) * math.cos(bLat) * math.cos(dLng);
    return (math.atan2(x, y) * 180 / math.pi + 360) % 360;
  }

  /// Linear interpolation for angles (handles 360° wraparound)
  double _lerpAngle(double from, double to, double t) {
    double diff = to - from;
    while (diff > 180) { diff -= 360; }
    while (diff < -180) { diff += 360; }
    return from + diff * t;
  }

  /// Fast double-returning pow for time-based exponential decay.
  double _pow(double base, double exp) => math.pow(base, exp).toDouble();

  // ═══════════════════════════════════════════════════════════
  //  MAPBOX ANNOTATION HELPERS
  // ═══════════════════════════════════════════════════════════

  Future<void> _setRouteAnnotation(List<LatLng> pts, Color c) async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null || pts.length < 2) return;
    final coords = pts.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    final geo = mapbox.LineString(coordinates: coords);
    if (_routeAnnot != null) {
      _routeAnnot!.geometry = geo;
      _routeAnnot!.lineColor = c.toARGB32();
      try { await polyMgr.update(_routeAnnot!); } catch (_) {}
    } else {
      _routeAnnot = await polyMgr.create(mapbox.PolylineAnnotationOptions(
        geometry: geo,
        lineColor: c.toARGB32(),
        lineWidth: 5.0,
        lineJoin: mapbox.LineJoin.ROUND,
      ));
    }
  }

  Future<void> _clearRouteAnnotation() async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null) return;
    for (final a in [_routeAnnot, _previewPickupAnnot, _previewDropoffAnnot]) {
      if (a != null) try { await polyMgr.delete(a); } catch (_) {}
    }
    _routeAnnot = null;
    _previewPickupAnnot = null;
    _previewDropoffAnnot = null;
  }

  Future<void> _setPickupAnnotation() async {
    final pointMgr = _pinAnnotMgr;
    if (pointMgr == null) return;
    await _clearPickupDropoffAnnotations();
    final bytes = await renderCircularPinBytes(icon: CircularPinIcon.person, isPickup: true, radius: 32);
    _pickupAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(coordinates: mapbox.Position(_pickupLL.longitude, _pickupLL.latitude)),
      image: bytes,
      iconSize: 1.0,
      iconAnchor: mapbox.IconAnchor.BOTTOM,
    ));
  }

  Future<void> _setDropoffAnnotation() async {
    final pointMgr = _pinAnnotMgr;
    if (pointMgr == null) return;
    await _clearPickupDropoffAnnotations();
    final bytes = await renderCircularPinBytes(icon: CircularPinIcon.flag, isPickup: false, radius: 32);
    _dropoffAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(coordinates: mapbox.Position(_dropoffLL.longitude, _dropoffLL.latitude)),
      image: bytes,
      iconSize: 1.0,
      iconAnchor: mapbox.IconAnchor.BOTTOM,
    ));
  }

  Future<void> _setPickupDropoffAnnotations() async {
    final pointMgr = _pinAnnotMgr;
    if (pointMgr == null) return;
    await _clearPickupDropoffAnnotations();
    final pickupBytes  = await renderCircularPinBytes(icon: CircularPinIcon.person, isPickup: true, radius: 32);
    final dropoffBytes = await renderCircularPinBytes(icon: CircularPinIcon.flag, isPickup: false, radius: 32);
    _pickupAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(coordinates: mapbox.Position(_pickupLL.longitude, _pickupLL.latitude)),
      image: pickupBytes,
      iconSize: 1.0,
      iconAnchor: mapbox.IconAnchor.BOTTOM,
    ));
    _dropoffAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(coordinates: mapbox.Position(_dropoffLL.longitude, _dropoffLL.latitude)),
      image: dropoffBytes,
      iconSize: 1.0,
      iconAnchor: mapbox.IconAnchor.BOTTOM,
    ));
  }

  Future<void> _clearPickupDropoffAnnotations() async {
    final pointMgr = _pinAnnotMgr;
    if (pointMgr == null) return;
    for (final annot in [_pickupAnnot, _dropoffAnnot, _prevDriverAnnot, _prevPickupAnnot, _prevDropoffAnnot]) {
      if (annot != null) try { await pointMgr.delete(annot); } catch (_) {}
    }
    _pickupAnnot = null;
    _dropoffAnnot = null;
    _prevDriverAnnot = null;
    _prevPickupAnnot = null;
    _prevDropoffAnnot = null;
  }

  Future<void> _clearAllAnnotations() async {
    await _clearRouteAnnotation();
    await _clearPickupDropoffAnnotations();
    final pointMgr = _pointAnnotMgr;
    if (pointMgr == null) return;
    for (final annot in [_carAnnot, _goldDotAnnot]) {
      if (annot != null) try { await pointMgr.delete(annot); } catch (_) {}
    }
    _carAnnot = null;
    _goldDotAnnot = null;
    _dotPopDone = false;
    _dotPopScale = 0.0;
  }

  String _mapRideType(String raw) {
    final lower = raw.toLowerCase().trim();
    if (lower.contains('premium')) return 'Premium';
    if (lower.contains('sedan')) return 'Sedan';
    if (lower.contains('comfort')) return 'Comfort';
    if (lower == 'cruisex' || lower == 'cruise_x' || lower == 'cruise') return 'Comfort';
    // Fallback: capitalize first letter
    if (raw.isEmpty) return 'Comfort';
    return raw[0].toUpperCase() + raw.substring(1);
  }

  double _hav(LatLng a, LatLng b) {
    const R = 6371.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final x =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return R * 2 * math.atan2(math.sqrt(x), math.sqrt(1 - x));
  }

  void _fitBounds(LatLng a, LatLng b) {
    _fitBoundsMulti([a, b]);
  }

  void _fitBoundsMulti(List<LatLng> points) {
    if (points.isEmpty || _map == null) return;
    final coords = points
        .map((p) => mapbox.Point(coordinates: mapbox.Position(p.longitude, p.latitude)))
        .toList();
    final botPad = MediaQuery.of(context).padding.bottom;
    final topPad = MediaQuery.of(context).padding.top;
    final hasCard = _pendingOffers.isNotEmpty || _previewingOffer != null;
    // Card height (~280) + bottom safe area + 60px breathing room
    final cardArea = hasCard ? 340.0 + botPad : 60.0;
    // Top: status bar + earnings bar (~56) + breathing room
    final topArea = topPad + 80.0;
    // Preserve current tilt/bearing if cinematic is active
    final currentPitch = _offerTiltAnim?.value ?? 0.0;
    final currentBearing = _offerBearingAnim?.value ?? 0.0;
    _map!.cameraForCoordinatesPadding(
      coords,
      mapbox.CameraOptions(
        pitch: currentPitch > 1 ? currentPitch : 0,
        bearing: currentBearing.abs() > 0.5 ? currentBearing : 0,
      ),
      mapbox.MbxEdgeInsets(top: topArea, left: 60, bottom: cardArea, right: 60),
      null, null,
    ).then((cam) {
      if (mounted) _map?.flyTo(cam, mapbox.MapAnimationOptions(duration: 700));
    });
  }

  /// Auto-trigger cinematic route preview when first offer arrives.
  /// Guards against duplicate triggers from SSE + polling overlap.
  void _autoTriggerRoutePreview(Map<String, dynamic> offer) {
    final oid = (offer['offer_id'] ?? offer['id'] ?? '').toString();
    if (oid == _lastAutoTriggeredOfferId) return; // already triggered for this offer
    // Don't re-trigger if this offer is already being previewed
    final currentPreviewId = (_previewingOffer?['offer_id'] ?? _previewingOffer?['id'] ?? '').toString();
    if (currentPreviewId == oid && _previewingOffer != null) return;
    _lastAutoTriggeredOfferId = oid;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingOffers.isEmpty || _isCardAnimating) return;
      _onOfferCardTap(offer);
    });
  }

  // ── Cinematic offer card tap → full animation sequence ──
  // Sequence: fit bounds → pins fade+pop → tilt 55° → draw seg1 (driver→pickup)
  //   → pickup pin popup → draw seg2 (pickup→dropoff) → dropoff pin popup → refit
  // Runs once per tap — no loops, no repeats.
  Future<void> _onOfferCardTap(Map<String, dynamic> offer) async {
    if (_isCardAnimating) return;
    final oid = (offer['offer_id'] ?? offer['id'] ?? '').toString();
    _isCardAnimating = true;

    final pickupLat  = (offer['pickup_lat']  as num?)?.toDouble() ?? 0;
    final pickupLng  = (offer['pickup_lng']  as num?)?.toDouble() ?? 0;
    final dropoffLat = (offer['dropoff_lat'] as num?)?.toDouble() ?? 0;
    final dropoffLng = (offer['dropoff_lng'] as num?)?.toDouble() ?? 0;
    final pickupLL  = LatLng(pickupLat,  pickupLng);
    final dropoffLL = LatLng(dropoffLat, dropoffLng);

    _setState(() {
      _previewingOffer = offer;
      _animatingOfferId = oid;
      _tappedCardIds.add(oid);
    });

    // Clear old annotations
    await _clearAllAnnotations();

    // Load from cache (pre-fetched on offer arrival)
    final cached = _routeCache[oid];
    if (cached != null) {
      _fullSegOne = cached.segOne;
      _fullSegTwo = cached.segTwo;
    } else {
      final routeFutures = await Future.wait([
        _fetchRoutePoints(_pos!, pickupLL),
        _fetchRoutePoints(pickupLL, dropoffLL),
      ]);
      _fullSegOne = routeFutures[0];
      _fullSegTwo = routeFutures[1];
    }
    if (!mounted || _previewingOffer == null) { _isCardAnimating = false; return; }

    // ── PHASE 1: Camera zoom to fit full route (flat, no tilt) ──
    _fitBoundsMulti([_pos!, pickupLL, dropoffLL]);
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted || _previewingOffer == null) { _isCardAnimating = false; return; }

    // ── PHASE 2: Create pins at size 0 (invisible) ──
    final dropoffAddr = (offer['dropoff_address'] ?? '') as String;
    final placeType = cached?.dropoffPlaceType ?? _detectPlaceType(dropoffAddr);
    Uint8List? pickupPinImg = cached?.pickupPin;
    Uint8List? dropoffPinImg = cached?.dropoffPin;
    if (pickupPinImg == null || dropoffPinImg == null) {
      final pinResults = await Future.wait([
        renderCircularPinBytes(icon: CircularPinIcon.person, isPickup: true, radius: 32),
        renderCircularPinBytes(icon: _goldPinIconFor(placeType), isPickup: false, radius: 32),
      ]);
      pickupPinImg ??= pinResults[0];
      dropoffPinImg ??= pinResults[1];
    }
    if (!mounted || _previewingOffer == null) { _isCardAnimating = false; return; }

    final pointMgr = _pinAnnotMgr;
    if (pointMgr != null && mounted) {
      _prevPickupAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(pickupLL.longitude, pickupLL.latitude)),
        image: pickupPinImg, iconSize: 0.01, iconAnchor: mapbox.IconAnchor.BOTTOM,
      ));
      _prevDropoffAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(dropoffLL.longitude, dropoffLL.latitude)),
        image: dropoffPinImg, iconSize: 0.01, iconAnchor: mapbox.IconAnchor.BOTTOM,
      ));
    }

    // ── PHASE 3: Tilt camera 0° → 55° ──
    if (!mounted || _previewingOffer == null) { _isCardAnimating = false; return; }

    final rng = math.Random();
    final degrees = 5.0 + rng.nextDouble() * 10.0;
    _offerRandomBearing = degrees * (rng.nextBool() ? 1.0 : -1.0);

    _offerTiltAnim?.removeListener(_applyOfferCamera);
    _offerTiltCtrl?.dispose();
    _offerTiltCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1050));
    _offerTiltAnim = Tween<double>(begin: 0.0, end: 55.0).animate(
      CurvedAnimation(parent: _offerTiltCtrl!, curve: Curves.easeInOutCubic),
    );
    _offerBearingCtrl?.dispose();
    _offerBearingCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1050));
    _offerBearingAnim = Tween<double>(begin: 0.0, end: _offerRandomBearing).animate(
      CurvedAnimation(parent: _offerBearingCtrl!, curve: Curves.easeInOutCubic),
    );
    _offerTiltAnim!.addListener(_applyOfferCamera);
    _offerTiltCtrl!.forward(from: 0);
    _offerBearingCtrl!.forward(from: 0);
    await Future.delayed(const Duration(milliseconds: 1100));
    if (!mounted || _previewingOffer == null) { _isCardAnimating = false; return; }

    // ── PHASE 4: Draw segment 1 (driver → pickup) ──
    if (_fullSegOne.length >= 2) {
      try {
        await _drawGoldGlossRoute(_fullSegOne).timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
    if (!mounted || _previewingOffer == null) { _isCardAnimating = false; return; }

    // ── PHASE 5: Pickup pin popup ──
    await _animateSinglePinPop(_prevPickupAnnot);
    await Future.delayed(const Duration(milliseconds: 200));
    if (!mounted || _previewingOffer == null) { _isCardAnimating = false; return; }

    // ── PHASE 6: Draw segment 2 (pickup → dropoff) ──
    if (_fullSegTwo.length >= 2) {
      try {
        await _drawGoldGlossRouteAppend(_fullSegTwo).timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
    if (!mounted || _previewingOffer == null) { _isCardAnimating = false; return; }

    // ── PHASE 7: Dropoff pin popup ──
    await _animateSinglePinPop(_prevDropoffAnnot);
    if (!mounted || _previewingOffer == null) { _isCardAnimating = false; return; }

    // ── PHASE 8: Refit with preserved tilt ──
    _fitBoundsMulti([_pos!, pickupLL, dropoffLL]);

    if (mounted && _previewingOffer != null) {
      _setState(() => _offerRouteShown = true);
    }
    _isCardAnimating = false;
  }

  /// Apply cinematic camera tilt + bearing per animation frame.
  void _applyOfferCamera() {
    if (_map == null || !mounted) return;
    _map!.setCamera(mapbox.CameraOptions(
      pitch: _offerTiltAnim?.value,
      bearing: _offerBearingAnim?.value,
    ));
  }

  /// Reset camera tilt/bearing to flat when dismissing offer preview.
  Future<void> _resetOfferCamera() async {
    _offerTiltAnim?.removeListener(_applyOfferCamera);
    _offerTiltCtrl?.stop();
    _offerBearingCtrl?.stop();
    if (_map != null && mounted) {
      _map!.flyTo(
        mapbox.CameraOptions(pitch: 0, bearing: 0),
        mapbox.MapAnimationOptions(duration: 500),
      );
    }
  }

  /// Spring scale curve: 0→1.2→0.9→1.0
  double _springScale(double t) {
    if (t < 0.6) {
      final p = (t / 0.6).clamp(0.0, 1.0);
      return Curves.easeOutCubic.transform(p) * 1.2;
    } else if (t < 0.8) {
      final p = ((t - 0.6) / 0.2).clamp(0.0, 1.0);
      return 1.2 - 0.3 * Curves.easeInOut.transform(p);
    } else {
      final p = ((t - 0.8) / 0.2).clamp(0.0, 1.0);
      return 0.9 + 0.1 * Curves.elasticOut.transform(p);
    }
  }

  /// Animate a single pin from tiny → overshoot → settle (spring feel)
  Future<void> _animateSinglePinPop(mapbox.PointAnnotation? annot) async {
    final pointMgr = _pinAnnotMgr;
    if (pointMgr == null || annot == null) return;
    const totalMs = 500;
    final stopwatch = Stopwatch()..start();
    final completer = Completer<void>();

    Ticker? ticker;
    ticker = createTicker((_) async {
      if (!mounted) {
        ticker?.stop();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      final elapsed = stopwatch.elapsedMilliseconds;
      final progress = (elapsed / totalMs).clamp(0.0, 1.0);
      final scale = _springScale(progress);
      annot.iconSize = scale;
      try { await pointMgr.update(annot); } catch (_) {}
      if (progress >= 1.0) {
        ticker?.stop();
        ticker?.dispose();
        if (!completer.isCompleted) completer.complete();
      }
    });
    ticker.start();
    return completer.future;
  }

  /// Animate all preview pins from tiny → overshoot → settle (spring feel)
  Future<void> _animatePinPop() async {
    final pointMgr = _pinAnnotMgr;
    if (pointMgr == null) return;
    const totalMs = 800;
    final stopwatch = Stopwatch()..start();
    final completer = Completer<void>();

    _pinPopTicker?.stop();
    _pinPopTicker?.dispose();
    _pinPopTicker = createTicker((_) async {
      if (!mounted) {
        _pinPopTicker?.stop();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      final elapsed = stopwatch.elapsedMilliseconds;
      final progress = (elapsed / totalMs).clamp(0.0, 1.0);
      final scale = _springScale(progress);

      for (final annot in [_prevPickupAnnot, _prevDropoffAnnot]) {
        if (annot != null) {
          annot.iconSize = scale;
          try { await pointMgr.update(annot); } catch (_) {}
        }
      }

      if (progress >= 1.0) {
        _pinPopTicker?.stop();
        if (!completer.isCompleted) completer.complete();
      }
    });
    _pinPopTicker!.start();
    return completer.future;
  }

  /// Draw a single gold route line with distance-based interpolation — smooth 60fps.
  Future<void> _drawGoldGlossRoute(List<LatLng> points) async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null || points.length < 2) return;

    // Pre-compute cumulative distances for distance-based interpolation
    final cumDist = <double>[0.0];
    for (int i = 1; i < points.length; i++) {
      cumDist.add(cumDist.last + _hav(points[i - 1], points[i]));
    }
    final totalDist = cumDist.last;
    if (totalDist < 1e-9) return;

    // Pre-create annotation before ticker to avoid async frame skipping
    final initCoords = points.sublist(0, 2).map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    mapbox.PolylineAnnotation? mainLine;
    try {
      mainLine = await polyMgr.create(mapbox.PolylineAnnotationOptions(
        geometry: mapbox.LineString(coordinates: initCoords),
        lineColor: const Color(0xFFFFD700).toARGB32(),
        lineWidth: 5.0,
        lineJoin: mapbox.LineJoin.ROUND,
      ));
    } catch (_) {}
    if (!mounted || mainLine == null) return;

    final totalMs = (points.length * 10).clamp(1800, 3500);
    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    bool updating = false;

    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = createTicker((_) {
      if (!mounted || _previewingOffer == null) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      if (updating) return;

      final elapsed = stopwatch.elapsedMilliseconds;
      final progress = (elapsed / totalMs).clamp(0.0, 1.0);
      // S-curve easing for smooth acceleration/deceleration
      final t = progress;
      final eased = t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3) / 2;
      final targetDist = eased * totalDist;

      // Find the segment where targetDist falls and interpolate tip point
      int segIdx = 0;
      for (int i = 1; i < cumDist.length; i++) {
        if (cumDist[i] >= targetDist) { segIdx = i - 1; break; }
        if (i == cumDist.length - 1) segIdx = i - 1;
      }
      final segLen = cumDist[segIdx + 1] - cumDist[segIdx];
      final frac = segLen > 1e-9 ? (targetDist - cumDist[segIdx]) / segLen : 1.0;
      final tipLat = points[segIdx].latitude + (points[segIdx + 1].latitude - points[segIdx].latitude) * frac;
      final tipLng = points[segIdx].longitude + (points[segIdx + 1].longitude - points[segIdx].longitude) * frac;

      // Build coords: all points up to segIdx + interpolated tip
      final coords = <mapbox.Position>[];
      for (int i = 0; i <= segIdx; i++) {
        coords.add(mapbox.Position(points[i].longitude, points[i].latitude));
      }
      coords.add(mapbox.Position(tipLng, tipLat));

      final ml = mainLine;
      if (coords.length >= 2 && ml != null) {
        ml.geometry = mapbox.LineString(coordinates: coords);
        updating = true;
        polyMgr.update(ml).then((_) => updating = false).catchError((_) => updating = false);
      }

      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        final fullCoords = points.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        if (ml != null) {
          ml.geometry = mapbox.LineString(coordinates: fullCoords);
          polyMgr.update(ml);
        }
        _previewPickupAnnot = mainLine;
        if (!completer.isCompleted) completer.complete();
      }
    });

    _routeDrawTicker!.start();
    return completer.future;
  }

  /// Draw a second gold route segment (appended as new polyline annotation).
  /// Used for the pickup→dropoff leg after the driver→pickup leg is drawn.
  Future<void> _drawGoldGlossRouteAppend(List<LatLng> points) async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null || points.length < 2) return;

    final cumDist = <double>[0.0];
    for (int i = 1; i < points.length; i++) {
      cumDist.add(cumDist.last + _hav(points[i - 1], points[i]));
    }
    final totalDist = cumDist.last;
    if (totalDist < 1e-9) return;

    final initCoords = points.sublist(0, 2).map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    mapbox.PolylineAnnotation? seg2Line;
    try {
      seg2Line = await polyMgr.create(mapbox.PolylineAnnotationOptions(
        geometry: mapbox.LineString(coordinates: initCoords),
        lineColor: const Color(0xFFFFD700).toARGB32(),
        lineWidth: 5.0,
        lineJoin: mapbox.LineJoin.ROUND,
      ));
    } catch (_) {}
    if (!mounted || seg2Line == null) return;

    final totalMs = (points.length * 10).clamp(1800, 3500);
    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    bool updating = false;

    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = createTicker((_) {
      if (!mounted || _previewingOffer == null) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      if (updating) return;

      final elapsed = stopwatch.elapsedMilliseconds;
      final progress = (elapsed / totalMs).clamp(0.0, 1.0);
      final t = progress;
      final eased = t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3) / 2;
      final targetDist = eased * totalDist;

      int segIdx = 0;
      for (int i = 1; i < cumDist.length; i++) {
        if (cumDist[i] >= targetDist) { segIdx = i - 1; break; }
        if (i == cumDist.length - 1) segIdx = i - 1;
      }
      final segLen = cumDist[segIdx + 1] - cumDist[segIdx];
      final frac = segLen > 1e-9 ? (targetDist - cumDist[segIdx]) / segLen : 1.0;
      final tipLat = points[segIdx].latitude + (points[segIdx + 1].latitude - points[segIdx].latitude) * frac;
      final tipLng = points[segIdx].longitude + (points[segIdx + 1].longitude - points[segIdx].longitude) * frac;

      final coords = <mapbox.Position>[];
      for (int i = 0; i <= segIdx; i++) {
        coords.add(mapbox.Position(points[i].longitude, points[i].latitude));
      }
      coords.add(mapbox.Position(tipLng, tipLat));

      final sl = seg2Line;
      if (coords.length >= 2 && sl != null) {
        sl.geometry = mapbox.LineString(coordinates: coords);
        updating = true;
        polyMgr.update(sl).then((_) => updating = false).catchError((_) => updating = false);
      }

      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        final fullCoords = points.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        if (sl != null) {
          sl.geometry = mapbox.LineString(coordinates: fullCoords);
          polyMgr.update(sl);
        }
        _previewDropoffAnnot = seg2Line;
        if (!completer.isCompleted) completer.complete();
      }
    });

    _routeDrawTicker!.start();
    return completer.future;
  }

  // Keep _previewOfferRoute for backward compat (delegates to cinematic tap)
  Future<void> _previewOfferRoute(Map<String, dynamic> offer) async {
    return _onOfferCardTap(offer);
  }

  /// Fetch route points from Google Directions → OSRM → straight line fallback
  Future<List<LatLng>> _fetchRoutePoints(LatLng o, LatLng d) async {
    List<LatLng>? pts;
    // Google Directions API
    try {
      final uri = Uri.https('maps.googleapis.com', '/maps/api/directions/json', {
        'origin': '${o.latitude},${o.longitude}',
        'destination': '${d.latitude},${d.longitude}',
        'key': ApiKeys.webServices,
        'mode': 'driving',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['status'] == 'OK' && (data['routes'] as List).isNotEmpty) {
          pts = _decodePoly(data['routes'][0]['overview_polyline']['points'] as String);
        }
      }
    } catch (_) {}
    // OSRM fallback
    if (pts == null) {
      try {
        final path = '/route/v1/driving/${o.longitude},${o.latitude};${d.longitude},${d.latitude}';
        final uri = Uri.https('router.project-osrm.org', path, {
          'overview': 'full', 'geometries': 'polyline',
        });
        final res = await http.get(uri).timeout(const Duration(seconds: 10));
        final data = jsonDecode(res.body);
        if (data is Map<String, dynamic> && data['code']?.toString().toUpperCase() == 'OK') {
          final routes = data['routes'] as List?;
          if (routes != null && routes.isNotEmpty) {
            pts = _decodePoly(routes[0]['geometry'] as String);
          }
        }
      } catch (_) {}
    }
    // Mapbox Directions API fallback
    if (pts == null) {
      try {
        final mbxUrl = Uri.parse(
          'https://api.mapbox.com/directions/v5/mapbox/driving/'
          '${o.longitude},${o.latitude};${d.longitude},${d.latitude}'
          '?geometries=geojson&overview=full&steps=false'
          '&access_token=${MapboxConfig.accessToken}',
        );
        final mbxRes = await http.get(mbxUrl).timeout(const Duration(seconds: 8));
        if (mbxRes.statusCode == 200) {
          final mbxData = jsonDecode(mbxRes.body);
          final mbxRoutes = mbxData['routes'] as List?;
          if (mbxRoutes != null && mbxRoutes.isNotEmpty) {
            final coords = mbxRoutes[0]['geometry']?['coordinates'] as List?;
            if (coords != null && coords.isNotEmpty) {
              pts = coords
                  .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
                  .toList();
            }
          }
        }
      } catch (_) {}
    }
    // Straight line fallback
    pts ??= List.generate(21, (i) {
      final t = i / 20;
      return LatLng(
        o.latitude  + (d.latitude  - o.latitude)  * t,
        o.longitude + (d.longitude - o.longitude) * t,
      );
    });
    return pts;
  }


  Future<void> _closePreview() async {
    _routePulseCtrl?.stop();
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = null;
    // Keep _lastAutoTriggeredOfferId so the same offer doesn't re-animate
    _offerTiltAnim?.removeListener(_applyOfferCamera);
    _offerTiltCtrl?.stop();
    _offerBearingCtrl?.stop();
    _setState(() {
      _previewingOffer = null;
      _offerRouteShown = false;
      _fullSegOne = [];
      _fullSegTwo = [];
    });
    await _clearAllAnnotations();
    if (_pos != null) _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          s,
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: _gold,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  MAP
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _applyMapStyle(bool isDark) {
    if (isDark == _lastStyleDark) return;
    _lastStyleDark = isDark;
    _setState(() {}); // rebuild map with new style
  }

  /// Called when a camera movement is initiated by user gesture.
  /// Pauses auto-follow so the driver can freely explore the map.
  void _onCameraMoveStarted() {
    // Only pause follow during active navigation phases
    final isNav =
        _phase == _Phase.enRouteToPickup ||
        _phase == _Phase.inTrip ||
        _phase == _Phase.routeSummary;
    if (!isNav) return;
    if (!_cameraFollowing) return; // already paused
    _setState(() => _cameraFollowing = false);
    _reFollowTimer?.cancel();
    // Auto-resume after 8 seconds of inactivity
    _reFollowTimer = Timer(const Duration(seconds: 8), _recenterCamera);
  }

  /// Resume camera follow mode and snap back to driver position.
  void _recenterCamera() {
    if (!mounted) return;
    _reFollowTimer?.cancel();
    _setState(() => _cameraFollowing = true);
    final bearing = _smoothedBearing;
    _cameraBearing = bearing; // sync for sprite selection
    if (_pos != null) _animateToPosition(_pos!, zoom: 17.5, bearing: bearing, tilt: 55);
  }
}
