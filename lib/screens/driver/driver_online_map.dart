part of 'driver_online_screen.dart';

// ══════════════════════════════════════════════════════════════
//  MAP — annotations, route preview, camera, pin builders
// ══════════════════════════════════════════════════════════════

extension _DriverOnlineMap on _DriverOnlineScreenState {
  /// Update the driver car / golden dot annotation on the Mapbox map.
  /// Write-then-flush update of the driver annotations (gold dot in
  /// searching mode, nav car in navigation mode). Same pattern as the
  /// rider home dot (1.0.2+376) — the previous full-await guard
  /// dropped every frame that landed mid-IPC, so the dot/car only
  /// moved ~1×/sec. Now we always write the freshest geometry into
  /// the in-memory annotation (cheap), and only fire mgr.update()
  /// when the previous IPC finished. The next IPC always carries the
  /// latest position, no information lost.
  Future<void> _updateDriverAnnotation() async {
    if (!mounted) return;
    await _updateDriverAnnotationInner();
  }

  Future<void> _updateDriverAnnotationInner() async {
    if (!mounted) return;
    if (_isClearingAnnotations) return;
    final pointMgr = _pointAnnotMgr;
    if (pointMgr == null || _pos == null) return;

    // Generation-based staleness check: if the map was recreated since
    // this annotation was created, the native object is gone. Null the
    // ref so a fresh one is created. Unlike geometry=self-assignment,
    // this never throws and is immune to zoom-induced SDK quirks.
    if (_goldDotAnnot != null && _goldDotAnnotGen != _mapGeneration) {
      _goldDotAnnot = null;
    }
    if (_carAnnot != null && _carAnnotGen != _mapGeneration) {
      _carAnnot = null;
    }

    final isNav = _phase == _Phase.enRouteToPickup ||
        _phase == _Phase.inTrip ||
        _phase == _Phase.routeSummary;

    if (!isNav) {
      // ── Searching mode: golden dot ──
      final dotBytes = _goldDot.currentBytes;
      if (dotBytes == null) return;

      // Remove car annotation if switching to gold dot
      if (_carAnnot != null && !_annotCreateBusy) {
        _annotCreateBusy = true;
        try {
          await pointMgr.delete(_carAnnot!);
        } catch (_) {}
        _carAnnot = null;
        _carAnnotGen = 0;
        _annotCreateBusy = false;
      }

      // Guard: skip update if GPS returned NaN (can happen briefly on iOS)
      if (!isValidLatLng(_pos!.latitude, _pos!.longitude)) {
        if (kDebugMode) {
          debugPrint(
              '[DriverOnlineMap] Skipping gold dot — invalid GPS: $_pos');
        }
        return;
      }

      // First-time creation: must guard so the per-frame ticker AND the
      // pop animation can't parallel-create N stacked dots.
      if (_goldDotAnnot == null) {
        if (_annotCreateBusy) return;
        _annotCreateBusy = true;
        try {
          _goldDotAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
            geometry: mapbox.Point(
                coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),
            image: dotBytes,
            iconSize: _dotPopScale,
            iconAnchor: mapbox.IconAnchor.CENTER,
            iconOffset: [0, 0],
            // The badge carries a heading arrow now, so it turns with the
            // driver — same _heading the nav car uses, already smoothed by
            // _motion (shortest-arc, low-passed).
            iconRotate: _heading,
            // Born hidden if the Flutter overlay is already drawing the
            // marker. Creation set no opacity, so a fresh annotation arrived
            // fully visible under an overlay painting the same arrow — two
            // arrows until something called this method again. The update
            // path below writes the opacity every time, so it did correct
            // itself, but only on the next tick: up to two seconds while the
            // driver is standing still and the watchdog is the only caller.
            iconOpacity: _dotOverlayOwnsMarker ? 0.0 : 1.0,
          ));
          _goldDotAnnotGen = _mapGeneration;
          if (!_dotPopDone) _animateDotPop();
        } catch (_) {
        } finally {
          _annotCreateBusy = false;
        }
        return;
      }

      // Subsequent updates: ALWAYS write fresh geometry into the in-memory
      // annotation (cheap, synchronous). Only gate the mgr.update() IPC call.
      // This ensures the dot never stalls between async flushes — every tick
      // carries the latest position, and the next update() always sends it.
      final overlayOwns = _dotOverlayOwnsMarker;
      try {
        _goldDotAnnot!.geometry = mapbox.Point(
            coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude));
        _goldDotAnnot!.image = dotBytes;
        // Invisible while the Flutter overlay is drawing the marker, or the
        // driver would see two: the smooth one and this one stepping behind
        // it. Kept alive and kept current rather than deleted, so the moment
        // they pan away it is already in the right place.
        _goldDotAnnot!.iconOpacity = overlayOwns ? 0.0 : 1.0;
        _goldDotAnnot!.iconSize = _dotPopScale;
        _goldDotAnnot!.iconRotate = _heading;
      } catch (_) {
        // Annotation became invalid (rare). Null it so next tick recreates.
        _goldDotAnnot = null;
        _goldDotAnnotGen = 0;
        return;
      }

      // While the overlay owns the marker there is nothing to look at here,
      // so send one flush to hide it and then leave the channel alone — the
      // map itself is what needs that bandwidth at sixty frames a second.
      if (overlayOwns && _goldDotHidden) return;
      _goldDotHidden = overlayOwns;

      // Fire update() only when previous IPC finished. If busy, the geometry
      // write above already captured the latest position — no info lost.
      if (_annotUpdateBusy) return;
      _annotUpdateBusy = true;
      try {
        await pointMgr.update(_goldDotAnnot!);
      } catch (_) {
        _goldDotAnnot = null;
        _goldDotAnnotGen = 0;
      } finally {
        _annotUpdateBusy = false;
      }
    } else if (isNav) {
      // ── Navigation mode: nav car icon ──
      // Remove dot annotation if switching to car
      if (_goldDotAnnot != null && !_annotCreateBusy) {
        _annotCreateBusy = true;
        try {
          await pointMgr.delete(_goldDotAnnot!);
        } catch (_) {}
        _goldDotAnnot = null;
        _goldDotAnnotGen = 0;
        _annotCreateBusy = false;
      }

      final Uint8List? navCarBytes =
          _navCarIconBytes ?? _vehicleIconBytes ?? _arrowIconBytes;
      if (navCarBytes == null) return;
      if (!isValidLatLng(_pos!.latitude, _pos!.longitude)) return;

      // First-time creation: must guard.
      if (_carAnnot == null) {
        if (_annotCreateBusy) return;
        _annotCreateBusy = true;
        try {
          _carAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
            geometry: mapbox.Point(
                coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),
            image: navCarBytes,
            iconSize: 1.2,
            iconRotate: _heading,
            iconAnchor: mapbox.IconAnchor.CENTER,
            iconOffset: [0, 0],
          ));
          _carAnnotGen = _mapGeneration;
          // Car icon rotates relative to map, not camera
          try {
            await _map?.style.setStyleLayerProperty(
                pointMgr.id, 'icon-rotation-alignment', 'map');
          } catch (_) {}
        } catch (_) {
        } finally {
          _annotCreateBusy = false;
        }
        return;
      }

      // Subsequent updates: write geometry every frame, flush when IPC free.
      try {
        _carAnnot!.geometry = mapbox.Point(
            coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude));
        _carAnnot!.iconRotate = _heading;
      } catch (_) {
        _carAnnot = null;
        _carAnnotGen = 0;
        return;
      }

      if (_annotUpdateBusy) return;
      _annotUpdateBusy = true;
      try {
        await pointMgr.update(_carAnnot!);
      } catch (_) {
        _carAnnot = null;
        _carAnnotGen = 0;
      } finally {
        _annotUpdateBusy = false;
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
      _dotPopScale = (i / riseSteps) * 1.15 * GoldLocationDot.driverIconSize;
      await _updateDriverAnnotation(); // await so frames don't pile up
    }
    // Phase 2: bounce back 1.15 → 1.0 over ~150 ms (9 frames × 16 ms)
    const bounceSteps = 9;
    for (int i = 1; i <= bounceSteps; i++) {
      await Future.delayed(const Duration(milliseconds: 16));
      if (!mounted) return;
      _dotPopScale =
          (1.15 - (0.15 * (i / bounceSteps))) * GoldLocationDot.driverIconSize;
      await _updateDriverAnnotation(); // await so frames don't pile up
    }
    _dotPopScale = GoldLocationDot.driverIconSize;
    await _settleDotSize();
  }

  /// Force the final 1.0 icon size onto the native annotation.
  ///
  /// The pop steps go through [_updateDriverAnnotation], which drops its
  /// flush whenever the previous IPC is still in flight. A `mgr.update()`
  /// round-trip routinely outlasts a 16 ms frame, so the LAST step — the one
  /// carrying the settled size — is the most likely of all to be dropped,
  /// leaving the dot frozen at whatever partial scale landed last (this is
  /// the "dot is smaller when online" report). The smooth ticker parks itself
  /// when the driver is stationary, so nothing corrects it afterwards.
  /// Retry until the IPC lane is free and the settled size actually lands.
  Future<void> _settleDotSize() async {
    for (int attempt = 0; attempt < 12; attempt++) {
      if (!mounted) return;
      final annot = _goldDotAnnot;
      final mgr = _pointAnnotMgr;
      if (annot == null || mgr == null) return;
      if (_annotUpdateBusy) {
        await Future.delayed(const Duration(milliseconds: 30));
        continue;
      }
      annot.iconSize = _dotPopScale;
      _annotUpdateBusy = true;
      try {
        await mgr.update(annot);
        return;
      } catch (_) {
        // Annotation went stale — next tick recreates it at the settled size.
        _goldDotAnnot = null;
        _goldDotAnnotGen = 0;
        return;
      } finally {
        _annotUpdateBusy = false;
      }
    }
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
    final y = math.cos(aLat) * math.sin(bLat) -
        math.sin(aLat) * math.cos(bLat) * math.cos(dLng);
    return (math.atan2(x, y) * 180 / math.pi + 360) % 360;
  }

  /// Linear interpolation for angles (handles 360° wraparound)
  double _lerpAngle(double from, double to, double t) {
    double diff = to - from;
    while (diff > 180) {
      diff -= 360;
    }
    while (diff < -180) {
      diff += 360;
    }
    return from + diff * t;
  }

  // ═══════════════════════════════════════════════════════════
  //  MAPBOX ANNOTATION HELPERS
  // ═══════════════════════════════════════════════════════════

  Future<void> _setRouteAnnotation(List<LatLng> pts, Color c) async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null || pts.length < 2) return;
    final safeGeom = safeLineString(pts);
    if (safeGeom == null) return;
    if (_routeAnnot != null) {
      _routeAnnot!.geometry = safeGeom;
      _routeAnnot!.lineColor = c.toARGB32();
      try {
        await polyMgr.update(_routeAnnot!);
      } catch (_) {}
    } else {
      _routeAnnot = await polyMgr.create(mapbox.PolylineAnnotationOptions(
        geometry: safeGeom,
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
      if (a != null) {
        try {
          await polyMgr.delete(a);
        } catch (_) {}
      }
    }
    _routeAnnot = null;
    _previewPickupAnnot = null;
    _previewDropoffAnnot = null;
  }

  Future<void> _setPickupAnnotation() async {
    final pointMgr = _pinAnnotMgr;
    if (pointMgr == null) return;
    final pickupPoint = safePoint(_pickupLL.longitude, _pickupLL.latitude);
    if (pickupPoint == null) return;
    await _clearPickupDropoffAnnotations();
    final bytes = await renderCircularPinBytes(
        icon: CircularPinIcon.person, isPickup: true, radius: 32);
    _pickupAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
      geometry: pickupPoint,
      image: bytes,
      iconSize: 1.0,
      iconAnchor: mapbox.IconAnchor.BOTTOM,
    ));
  }

  Future<void> _setDropoffAnnotation() async {
    final pointMgr = _pinAnnotMgr;
    if (pointMgr == null) return;
    final dropoffPoint = safePoint(_dropoffLL.longitude, _dropoffLL.latitude);
    if (dropoffPoint == null) return;
    await _clearPickupDropoffAnnotations();
    final bytes = await renderCircularPinBytes(
        icon: CircularPinIcon.flag, isPickup: false, radius: 32);
    _dropoffAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
      geometry: dropoffPoint,
      image: bytes,
      iconSize: 1.0,
      iconAnchor: mapbox.IconAnchor.BOTTOM,
    ));
  }

  Future<void> _setPickupDropoffAnnotations() async {
    final pointMgr = _pinAnnotMgr;
    if (pointMgr == null) return;
    final pickupPoint = safePoint(_pickupLL.longitude, _pickupLL.latitude);
    final dropoffPoint = safePoint(_dropoffLL.longitude, _dropoffLL.latitude);
    if (pickupPoint == null || dropoffPoint == null) return;
    await _clearPickupDropoffAnnotations();
    final pickupBytes = await renderCircularPinBytes(
        icon: CircularPinIcon.person, isPickup: true, radius: 32);
    final dropoffBytes = await renderCircularPinBytes(
        icon: CircularPinIcon.flag, isPickup: false, radius: 32);
    _pickupAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
      geometry: pickupPoint,
      image: pickupBytes,
      iconSize: 1.0,
      iconAnchor: mapbox.IconAnchor.BOTTOM,
    ));
    _dropoffAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
      geometry: dropoffPoint,
      image: dropoffBytes,
      iconSize: 1.0,
      iconAnchor: mapbox.IconAnchor.BOTTOM,
    ));
  }

  Future<void> _clearPickupDropoffAnnotations() async {
    final pointMgr = _pinAnnotMgr;
    if (pointMgr == null) return;
    for (final annot in [
      _pickupAnnot,
      _dropoffAnnot,
      _prevDriverAnnot,
      _prevPickupAnnot,
      _prevDropoffAnnot
    ]) {
      if (annot != null) {
        try {
          await pointMgr.delete(annot);
        } catch (_) {}
      }
    }
    _pickupAnnot = null;
    _dropoffAnnot = null;
    _prevDriverAnnot = null;
    _prevPickupAnnot = null;
    _prevDropoffAnnot = null;
  }

  Future<void> _clearAllAnnotations() async {
    _isClearingAnnotations = true;
    try {
      // Clear route polylines first
      await _clearRouteAnnotation();
      // Clear pickup/dropoff/preview pins
      await _clearPickupDropoffAnnotations();
      // Clear driver car / gold dot annotations on the main point manager.
      // If the manager is stale (map recreated), delete may throw — swallow
      // and null the reference so the next tick recreates on the fresh map.
      final pointMgr = _pointAnnotMgr;
      if (pointMgr != null) {
        for (final annot in [_carAnnot, _goldDotAnnot]) {
          if (annot != null) {
            try {
              await pointMgr.delete(annot);
            } catch (_) {}
          }
        }
      }
      _carAnnot = null;
      _carAnnotGen = 0;
      _goldDotAnnot = null;
      _goldDotAnnotGen = 0;
      _dotPopDone = false;
      _dotPopScale = 0.0;
    } finally {
      _isClearingAnnotations = false;
    }
  }

  String _mapRideType(String raw) {
    final lower = raw.toLowerCase().trim();
    if (lower.contains('premium')) return 'Premium';
    if (lower.contains('sedan')) return 'Sedan';
    if (lower.contains('comfort')) return 'Comfort';
    if (lower == 'cruisex' || lower == 'cruise_x' || lower == 'cruise') {
      return 'Comfort';
    }
    // Fallback: capitalize first letter
    if (raw.isEmpty) return 'Comfort';
    return raw[0].toUpperCase() + raw.substring(1);
  }

  double _hav(LatLng a, LatLng b) {
    const R = 6371.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final x = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return R * 2 * math.atan2(math.sqrt(x), math.sqrt(1 - x));
  }

  Future<void> _fitBounds(LatLng a, LatLng b) async {
    await _fitBoundsMulti([a, b]);
  }

  /// The points the camera has to keep on screen: both ends, and enough of
  /// the road between them that no part of the drawn line falls outside.
  ///
  /// Sampled rather than passed whole — a cross-town route is hundreds of
  /// points, and every one of them is serialised across to the native SDK
  /// for a bounding box that a few dozen describe just as well.
  List<LatLng> _routeFramePoints(
    LatLng driverPos,
    LatLng pickupLL,
    LatLng dropoffLL,
  ) {
    final pts = <LatLng>[driverPos, pickupLL, dropoffLL];
    for (final seg in [_fullSegOne, _fullSegTwo]) {
      if (seg.length < 3) continue;
      final step = (seg.length / 24).ceil().clamp(1, seg.length);
      for (var i = 0; i < seg.length; i += step) {
        pts.add(seg[i]);
      }
      pts.add(seg.last);
    }
    // A NaN here reaches cameraForCoordinatesPadding as a JSON null and
    // throws in Objective-C, taking the whole preview with it.
    return pts
        .where((p) =>
            p.latitude.isFinite &&
            p.longitude.isFinite &&
            p.latitude.abs() <= 90 &&
            p.longitude.abs() <= 180)
        .toList();
  }

  Future<void> _fitBoundsMulti(List<LatLng> points) async {
    if (points.isEmpty || _map == null) return;
    final coords = points
        .map((p) =>
            mapbox.Point(coordinates: mapbox.Position(p.longitude, p.latitude)))
        .toList();
    final botPad = MediaQuery.of(context).padding.bottom;
    final topPad = MediaQuery.of(context).padding.top;
    final hasCard = _pendingOffers.isNotEmpty || _previewingOffer != null;
    // The card's real height plus its header, so the route is framed in
    // the strip of map that is actually visible above it. 340 was a guess
    // from when the card was shorter.
    var cardArea = hasCard ? _offerCardHeight(context) + 56.0 + botPad : 60.0;
    // Top: status bar + earnings bar (~56) + breathing room
    var topArea = topPad + 80.0;

    // Never reserve so much that there is no map left to frame in.
    //
    // The card is about 396 pt tall. On a 667 pt screen — an iPhone SE —
    // that plus the header and the top bar leaves 116 pt, and a route
    // squeezed into 116 pt is a thread. Worse, nothing stopped the two
    // insets from exceeding the viewport entirely, and
    // cameraForCoordinatesPadding given more padding than screen does not
    // fail loudly: it hands back a camera that frames nothing.
    //
    // A third of the screen is kept for the route. The card still covers
    // what it covers — this only stops the *camera* from pretending the
    // strip is smaller than a third, which zooms the route down to
    // nothing to satisfy a box it cannot fit in anyway.
    final screenH = MediaQuery.of(context).size.height;
    final maxInsets = screenH * 0.65;
    if (topArea + cardArea > maxInsets) {
      final scale = maxInsets / (topArea + cardArea);
      topArea *= scale;
      cardArea *= scale;
      debugPrint('[OfferRoute] insets trimmed to fit a ${screenH.round()}pt '
          'screen: top=${topArea.round()} bottom=${cardArea.round()}');
    }
    // Preserve current tilt/bearing if cinematic is active
    final currentPitch = _offerTiltAnim?.value ?? 0.0;
    final currentBearing = _offerBearingAnim?.value ?? 0.0;
    try {
      final cam = await _map!.cameraForCoordinatesPadding(
        coords,
        mapbox.CameraOptions(
          pitch: currentPitch > 1 ? currentPitch : 0,
          bearing: currentBearing.abs() > 0.5 ? currentBearing : 0,
        ),
        mapbox.MbxEdgeInsets(
            top: topArea, left: 60, bottom: cardArea, right: 60),
        null,
        null,
      );
      if (mounted) {
        await _map?.flyTo(cam, mapbox.MapAnimationOptions(duration: 700));
      }
    } catch (e) {
      debugPrint('[DriverOnline] _fitBoundsMulti error: $e');
    }
  }

  /// Auto-trigger cinematic route preview when first offer arrives.
  /// Guards against duplicate triggers from SSE + polling overlap.
  void _autoTriggerRoutePreview(Map<String, dynamic> offer) {
    final oid = (offer['offer_id'] ?? offer['id'] ?? '').toString();
    if (oid == _lastAutoTriggeredOfferId) {
      return; // already triggered for this offer
    }
    // Don't re-trigger if this offer is already being previewed
    final currentPreviewId =
        (_previewingOffer?['offer_id'] ?? _previewingOffer?['id'] ?? '')
            .toString();
    if (currentPreviewId == oid && _previewingOffer != null) return;
    _lastAutoTriggeredOfferId = oid;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingOffers.isEmpty || _isCardAnimating) {
        debugPrint('[OfferRoute] auto-trigger skipped for $oid — '
            'mounted=$mounted offers=${_pendingOffers.length} '
            'animating=$_isCardAnimating');
        return;
      }
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

    final pickupLat = _safeDouble(offer['pickup_lat']);
    final pickupLng = _safeDouble(offer['pickup_lng']);
    final dropoffLat = _safeDouble(offer['dropoff_lat']);
    final dropoffLng = _safeDouble(offer['dropoff_lng']);
    final pickupLL = LatLng(pickupLat, pickupLng);
    final dropoffLL = LatLng(dropoffLat, dropoffLng);
    final driverPos = _pos ?? pickupLL; // fallback when GPS hasn't resolved yet

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
        _fetchRoutePoints(driverPos, pickupLL),
        _fetchRoutePoints(pickupLL, dropoffLL),
      ]);
      _fullSegOne = routeFutures[0];
      _fullSegTwo = routeFutures[1];
    }
    debugPrint('[OfferRoute] $oid segments: '
        '${_fullSegOne.length} + ${_fullSegTwo.length} points'
        '${cached != null ? " (cached)" : ""}');
    if (!mounted || _previewingOffer == null) {
      _isCardAnimating = false;
      return;
    }

    // ── PHASE 1: Frame the whole route, flat ──
    //
    // The three endpoints are not the route. A road that swings wide of
    // the straight line between them — a river crossing, a highway that
    // doubles back — draws outside a frame built from the ends alone, and
    // the driver sees a line leaving the screen.
    //
    // cameraForCoordinatesPadding already works out the zoom from the
    // spread of what it is given, so a short hop and a cross-town run each
    // get the zoom they need; it just has to be given the real shape.
    await _fitBoundsMulti(_routeFramePoints(driverPos, pickupLL, dropoffLL));
    if (!mounted || _previewingOffer == null) {
      _isCardAnimating = false;
      return;
    }

    // ── PHASE 2: Create pins at size 0 (invisible) ──
    // A gold disc and a white square — the same two shapes the card uses
    // for these stops. The cached pins are ignored on purpose: they hold
    // the old teardrop pins, and mixing the two would give the driver a
    // different marker depending on whether the route had been fetched.
    final pinResults = await Future.wait([
      renderPickupDotBytes(),
      renderDropoffSquareBytes(),
    ]);
    final Uint8List pickupPinImg = pinResults[0];
    final Uint8List dropoffPinImg = pinResults[1];
    if (!mounted || _previewingOffer == null) {
      _isCardAnimating = false;
      return;
    }

    final pointMgr = _pinAnnotMgr;
    if (pointMgr != null && mounted) {
      _prevPickupAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(
            coordinates:
                mapbox.Position(pickupLL.longitude, pickupLL.latitude)),
        image: pickupPinImg,
        iconSize: 0.01,
        iconAnchor: mapbox.IconAnchor.CENTER,
      ));
      _prevDropoffAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(
            coordinates:
                mapbox.Position(dropoffLL.longitude, dropoffLL.latitude)),
        image: dropoffPinImg,
        iconSize: 0.01,
        iconAnchor: mapbox.IconAnchor.CENTER,
      ));
    }

    // ── PHASE 3: none ──
    //
    // This used to tilt to 55° and swing to a random bearing over 1.05s,
    // right after the fit had framed the route flat. The result was a
    // camera that settled and then tipped over on its own, which is what
    // the driver saw as the view "restarting". A route is read as a shape
    // between two points; a tilt turns the far half into a smear.
    //
    // Top-down, no rotation, and the fit above already leaves the card's
    // height clear at the bottom so the whole route sits above it.
    _offerTiltAnim?.removeListener(_applyOfferCamera);
    _offerTiltAnim = null;
    _offerBearingAnim = null;
    _offerTiltCtrl?.dispose();
    _offerTiltCtrl = null;
    _offerBearingCtrl?.dispose();
    _offerBearingCtrl = null;
    _offerRandomBearing = 0;
    if (!mounted || _previewingOffer == null) {
      _isCardAnimating = false;
      return;
    }

    // ── PHASE 4: Draw segment 1 (driver → pickup) ──
    if (_fullSegOne.length >= 2) {
      try {
        await _drawGoldGlossRoute(
          _fullSegOne,
          // The draw takes time. Without this it finishes after the
          // offer was dismissed and paints a route onto an empty map —
          // which is how a yellow line was left over the "You're
          // online" screen with no card to explain it.
          stillWanted: () => mounted && _previewingOffer != null,
        ).timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
    if (!mounted || _previewingOffer == null) {
      _isCardAnimating = false;
      return;
    }

    // ── PHASE 5: Pickup pin popup ──
    await _animateSinglePinPop(_prevPickupAnnot);
    await Future.delayed(const Duration(milliseconds: 200));
    if (!mounted || _previewingOffer == null) {
      _isCardAnimating = false;
      return;
    }

    // ── PHASE 6: Draw segment 2 (pickup → dropoff) ──
    if (_fullSegTwo.length >= 2) {
      try {
        await _drawGoldGlossRouteAppend(
          _fullSegTwo,
          stillWanted: () => mounted && _previewingOffer != null,
        ).timeout(const Duration(seconds: 8));
      } catch (_) {}
    }
    if (!mounted || _previewingOffer == null) {
      _isCardAnimating = false;
      return;
    }

    // ── PHASE 7: Dropoff pin popup ──
    await _animateSinglePinPop(_prevDropoffAnnot);
    if (!mounted || _previewingOffer == null) {
      _isCardAnimating = false;
      return;
    }

    // ── PHASE 8: Refit with preserved tilt ──
    _fitBoundsMulti([driverPos, pickupLL, dropoffLL]);

    if (mounted && _previewingOffer != null) {
      _setState(() => _offerRouteShown = true);
    }
    _isCardAnimating = false;
  }

  /// Apply cinematic camera tilt + bearing per animation frame.
  /// Every camera write on this screen, in one guarded place.
  ///
  /// The handle outlives the native view: `_map` is only cleared once
  /// _releaseMapSurface runs, so between the coordinator revoking us and
  /// that teardown finishing, and again while a remount is in flight, it
  /// points at a view that is going away. Calling into that is a native
  /// crash, not a Dart exception — which is how a tap on recenter, or a
  /// couple of trips through offline/online, closed the app.
  void _camera(mapbox.CameraOptions options, {int? animateMs}) {
    if (!mounted || !_mapMounted) return;
    final map = _map;
    if (map == null) return;
    if (!_cameraIsFinite(options)) return;
    try {
      final Future<void> f = animateMs == null
          ? map.setCamera(options)
          : map.flyTo(options, mapbox.MapAnimationOptions(duration: animateMs));
      // Rejected asynchronously when the view is destroyed mid-flight; the
      // try/catch below only sees synchronous throws.
      f.catchError((Object e) {
        debugPrint('[DriverOnline] camera write rejected: $e');
      });
    } catch (e) {
      debugPrint('[DriverOnline] camera write failed: $e');
    }
  }

  /// True when every number in [options] is one Mapbox can use.
  ///
  /// NaN reaches the native SDK and throws there, not here:
  ///
  ///   specialized FlyToInterpolator.init(from:to:cameraBounds:size:)
  ///   MapboxMaps/Projection.swift:59 — "latitude must not be NaN"
  ///
  /// A Swift precondition is not a Dart exception. Nothing catches it and the
  /// app closes on the spot, which is what a driver tapping recenter saw.
  /// Crashlytics has it on every version from 1.0.3 to 1.0.9.
  ///
  /// NaN gets in easily. lerpDouble with a null end returns it, a heading
  /// divided by a zero-length vector returns it, and a location fix that has
  /// not arrived leaves the field it was going to fill as double.nan rather
  /// than null — so the usual null check waves it through.
  ///
  /// Dropping the write is the right failure: the camera stays where it is,
  /// which is a frame of staleness against a crash that ends the shift.
  static bool _cameraIsFinite(mapbox.CameraOptions o) {
    bool ok(num? v) => v == null || v.isFinite;
    final c = o.center?.coordinates;
    if (c != null && !(c.lat.isFinite && c.lng.isFinite)) {
      debugPrint('[DriverOnline] camera write dropped — centre is not finite');
      return false;
    }
    if (!ok(o.zoom) || !ok(o.bearing) || !ok(o.pitch)) {
      debugPrint(
          '[DriverOnline] camera write dropped — zoom/bearing/pitch NaN');
      return false;
    }
    return true;
  }

  void _applyOfferCamera() {
    _camera(mapbox.CameraOptions(
      pitch: _offerTiltAnim?.value,
      bearing: _offerBearingAnim?.value,
    ));
  }

  /// Reset camera tilt/bearing to flat when dismissing offer preview.
  Future<void> _resetOfferCamera() async {
    _offerTiltAnim?.removeListener(_applyOfferCamera);
    _offerTiltCtrl?.stop();
    _offerBearingCtrl?.stop();
    _camera(mapbox.CameraOptions(pitch: 0, bearing: 0), animateMs: 500);
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
      try {
        await pointMgr.update(annot);
      } catch (_) {}
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
          try {
            await pointMgr.update(annot);
          } catch (_) {}
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
  ///
  /// [stillWanted] decides, per frame, whether the draw is still relevant.
  /// It defaults to "an offer preview is open", which is what every caller
  /// wanted until the accepted-trip celebration started drawing on this
  /// same canvas — by then `_previewingOffer` is already null, so without
  /// an override the ticker would bail on its first frame and leave a
  /// two-point stub on the map.
  Future<void> _drawGoldGlossRoute(
    List<LatLng> points, {
    bool Function()? stillWanted,
  }) async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null || points.length < 2) {
      // This used to return in silence, which is indistinguishable from
      // "the route drew fine" anywhere except on the screen.
      debugPrint('[OfferRoute] not drawn — '
          'mgr=${polyMgr != null} points=${points.length}');
      return;
    }
    bool wanted() =>
        stillWanted != null ? stillWanted() : _previewingOffer != null;

    // Pre-compute cumulative distances for distance-based interpolation
    final cumDist = <double>[0.0];
    for (int i = 1; i < points.length; i++) {
      cumDist.add(cumDist.last + _hav(points[i - 1], points[i]));
    }
    final totalDist = cumDist.last;
    if (totalDist < 1e-9) return;

    // Pre-create annotation before ticker to avoid async frame skipping
    final initSafe = safeLineString(points.sublist(0, 2));
    if (initSafe == null) return;
    mapbox.PolylineAnnotation? mainLine;
    try {
      mainLine = await polyMgr.create(mapbox.PolylineAnnotationOptions(
        geometry: initSafe,
        lineColor: const Color(0xFFFFD700).toARGB32(),
        lineWidth: 5.0,
        lineJoin: mapbox.LineJoin.ROUND,
      ));
    } catch (_) {}
    if (mainLine == null) return;
    if (!mounted || !wanted()) {
      // Dismissed while create() was in flight: the clear has already run,
      // so this line would outlive the offer that asked for it.
      try {
        await polyMgr.delete(mainLine);
      } catch (_) {}
      return;
    }

    final totalMs = (points.length * 10).clamp(1800, 3500);
    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    bool updating = false;

    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = createTicker((_) {
      if (!mounted || !wanted()) {
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
        if (cumDist[i] >= targetDist) {
          segIdx = i - 1;
          break;
        }
        if (i == cumDist.length - 1) segIdx = i - 1;
      }
      final segLen = cumDist[segIdx + 1] - cumDist[segIdx];
      final frac =
          segLen > 1e-9 ? (targetDist - cumDist[segIdx]) / segLen : 1.0;
      final tipLat = points[segIdx].latitude +
          (points[segIdx + 1].latitude - points[segIdx].latitude) * frac;
      final tipLng = points[segIdx].longitude +
          (points[segIdx + 1].longitude - points[segIdx].longitude) * frac;
      if (!isValidLatLng(tipLat, tipLng)) return;

      // Build coords: all points up to segIdx + interpolated tip
      final coords = <mapbox.Position>[];
      for (int i = 0; i <= segIdx; i++) {
        coords.add(mapbox.Position(points[i].longitude, points[i].latitude));
      }
      coords.add(mapbox.Position(tipLng, tipLat));

      final ml = mainLine;
      final safeCoords = coords
          .where((p) => isValidLatLng(p.lat.toDouble(), p.lng.toDouble()))
          .toList();
      if (safeCoords.length >= 2 && ml != null) {
        ml.geometry = mapbox.LineString(coordinates: safeCoords);
        updating = true;
        polyMgr
            .update(ml)
            .then((_) => updating = false)
            .catchError((_) => updating = false);
      }

      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        final fullSafe = safeLineString(points);
        if (fullSafe != null && ml != null) {
          ml.geometry = fullSafe;
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
  Future<void> _drawGoldGlossRouteAppend(
    List<LatLng> points, {
    bool Function()? stillWanted,
  }) async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null || points.length < 2) return;
    bool wanted() =>
        stillWanted != null ? stillWanted() : _previewingOffer != null;

    final cumDist = <double>[0.0];
    for (int i = 1; i < points.length; i++) {
      cumDist.add(cumDist.last + _hav(points[i - 1], points[i]));
    }
    final totalDist = cumDist.last;
    if (totalDist < 1e-9) return;

    final initSafe = safeLineString(points.sublist(0, 2));
    if (initSafe == null) return;
    mapbox.PolylineAnnotation? seg2Line;
    try {
      seg2Line = await polyMgr.create(mapbox.PolylineAnnotationOptions(
        geometry: initSafe,
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
      if (!mounted || !wanted()) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
        // Take the half-drawn line back with it.
        final stale = seg2Line;
        if (stale != null) {
          polyMgr.delete(stale).catchError((_) {});
        }
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
        if (cumDist[i] >= targetDist) {
          segIdx = i - 1;
          break;
        }
        if (i == cumDist.length - 1) segIdx = i - 1;
      }
      final segLen = cumDist[segIdx + 1] - cumDist[segIdx];
      final frac =
          segLen > 1e-9 ? (targetDist - cumDist[segIdx]) / segLen : 1.0;
      final tipLat = points[segIdx].latitude +
          (points[segIdx + 1].latitude - points[segIdx].latitude) * frac;
      final tipLng = points[segIdx].longitude +
          (points[segIdx + 1].longitude - points[segIdx].longitude) * frac;
      if (!isValidLatLng(tipLat, tipLng)) return;

      final coords = <mapbox.Position>[];
      for (int i = 0; i <= segIdx; i++) {
        coords.add(mapbox.Position(points[i].longitude, points[i].latitude));
      }
      coords.add(mapbox.Position(tipLng, tipLat));

      final sl = seg2Line;
      final safeCoords = coords
          .where((p) => isValidLatLng(p.lat.toDouble(), p.lng.toDouble()))
          .toList();
      if (safeCoords.length >= 2 && sl != null) {
        sl.geometry = mapbox.LineString(coordinates: safeCoords);
        updating = true;
        polyMgr
            .update(sl)
            .then((_) => updating = false)
            .catchError((_) => updating = false);
      }

      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        final fullSafe = safeLineString(points);
        if (fullSafe != null && sl != null) {
          sl.geometry = fullSafe;
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
      final uri =
          Uri.https('maps.googleapis.com', '/maps/api/directions/json', {
        'origin': '${o.latitude},${o.longitude}',
        'destination': '${d.latitude},${d.longitude}',
        'key': ApiKeys.webServices,
        'mode': 'driving',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['status'] == 'OK' && (data['routes'] as List).isNotEmpty) {
          pts = _decodePoly(
              data['routes'][0]['overview_polyline']['points'] as String);
        }
      }
    } catch (_) {}
    // OSRM fallback
    if (pts == null) {
      try {
        final path =
            '/route/v1/driving/${o.longitude},${o.latitude};${d.longitude},${d.latitude}';
        final uri = Uri.https('router.project-osrm.org', path, {
          'overview': 'full',
          'geometries': 'polyline',
        });
        final res = await http.get(uri).timeout(const Duration(seconds: 10));
        final data = jsonDecode(res.body);
        if (data is Map<String, dynamic> &&
            data['code']?.toString().toUpperCase() == 'OK') {
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
        final mbxRes =
            await http.get(mbxUrl).timeout(const Duration(seconds: 8));
        if (mbxRes.statusCode == 200) {
          final mbxData = jsonDecode(mbxRes.body);
          final mbxRoutes = mbxData['routes'] as List?;
          if (mbxRoutes != null && mbxRoutes.isNotEmpty) {
            final coords = mbxRoutes[0]['geometry']?['coordinates'] as List?;
            if (coords != null && coords.isNotEmpty) {
              pts = coords
                  .map((c) => LatLng(
                      (c[1] as num).toDouble(), (c[0] as num).toDouble()))
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
        o.latitude + (d.latitude - o.latitude) * t,
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
    if (_pos != null) {
      _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
    }
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
  ///
  /// Applies in every phase now. It used to return early unless the driver
  /// was navigating, so while merely online the camera re-centred on them
  /// sixty times a second — the map fought the finger and sprang back the
  /// instant they let go.
  ///
  /// The marker keeps tracking the whole time. It stops being the Flutter
  /// overlay pinned to the centre and becomes the Mapbox annotation at its
  /// true coordinates, so a driver who has panned away still sees exactly
  /// where they are, off to the side of the view or off screen entirely.
  void _onCameraMoveStarted() {
    _lastMapPanAt = DateTime.now();
    _reFollowTimer?.cancel();
    // A recentre in flight is abandoned the moment the driver grabs the map
    // again — otherwise its resume would fire mid-gesture and snap the view
    // out from under their finger. Only a finger reaches this method: it is
    // wired to onScrollListener, which a programmatic flyTo does not trip.
    _followResumeTimer?.cancel();
    // Auto-resume ten seconds after the last drag, not ten seconds after the
    // first: a driver still moving the map around should not have it yanked
    // out from under them mid-gesture.
    _reFollowTimer = Timer(const Duration(seconds: 10), _recenterCamera);
    if (!_cameraFollowing) return; // already paused
    _setState(() => _cameraFollowing = false);
  }

  /// Resume camera follow mode and glide back to the driver.
  ///
  /// The follow flag is set when the glide *lands*, not when it starts.
  ///
  /// It used to be set first, and that flag is what tells the overlay to
  /// stop projecting the driver's real pixel and draw itself in the middle
  /// of the screen instead. So the arrow teleported to the centre on the tap
  /// and the map spent the next 600 ms flying to meet it — the driver
  /// watched their own position let go of the street it was on. Holding the
  /// flag until the camera has arrived keeps the arrow on the ground the
  /// whole way: the map slides under it and it ends up centred because it
  /// really is, not because it was told to be.
  void _recenterCamera() {
    if (!mounted) return;
    _reFollowTimer?.cancel();
    _followResumeTimer?.cancel();
    final bearing = _smoothedBearing;
    _cameraBearing = bearing; // sync for sprite selection
    if (_pos == null) {
      // No position to fly to, so there is no flight to wait out.
      _setState(() => _cameraFollowing = true);
      return;
    }
    final isNav = _phase == _Phase.enRouteToPickup ||
        _phase == _Phase.inTrip ||
        _phase == _Phase.routeSummary;
    if (isNav) {
      _animateToPosition(_pos!, zoom: 17.5, bearing: bearing, tilt: 55);
    } else {
      // Searching: flat and north-up, the framing this phase already uses.
      // Recentring into a tilted nav view here would be a different screen.
      _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
    }

    // The flyTo above runs for _kRecenterFlightMs. A little past that, the
    // camera is where the marker already is and handing the overlay back to
    // its centred mode changes nothing on screen.
    //
    // Not awaited: flyTo's future resolves on the native side and is
    // rejected outright if the view goes away mid-flight, so the resume
    // would be lost exactly when the driver most needs the camera to come
    // back. A timer always fires, and _onCameraMoveStarted cancels it if
    // they grab the map again.
    _followResumeTimer = Timer(
      const Duration(milliseconds: _kRecenterFlightMs + 40),
      () {
        if (!mounted) return;
        _setState(() => _cameraFollowing = true);
      },
    );
  }

  /// True while the marker is the Flutter overlay rather than the Mapbox
  /// annotation.
  ///
  /// Two ways to earn it. Camera glued to the driver: the marker sits at the
  /// centre of the viewport by construction, no arithmetic needed. Camera
  /// left somewhere by the driver's finger: still fine, because a parked
  /// camera plus [FlatMapProjection] gives the exact pixel — as long as the
  /// view is flat. The tilted navigation camera is the one case that falls
  /// back to the annotation, and FlatMapProjection decides that itself by
  /// returning null, so there is no phase check here to keep in sync.
  bool get _dotOverlayOwnsMarker {
    if (_pos == null) return false;
    // Nothing else is drawing it, so we do — whatever the rules below say.
    //
    // Every branch here hands the marker to the Mapbox annotation, which is
    // fine while that annotation exists. It does not exist in the window
    // after a remount: coming back from another screen, resuming the app,
    // going offline and online again. The annotation is destroyed with the
    // surface and takes a moment to be rebuilt, and if the driver looked in
    // that window the arrow was simply gone.
    if (_goldDotAnnot == null) return true;
    // An offer preview flies the camera around the route. The overlay is
    // positioned from camera-change events, which arrive over the same
    // channel we are avoiding — during an animation they lag, and a marker
    // that lags a moving camera slides across the map. The annotation is
    // anchored in map space and rides the animation correctly, so it wins
    // here.
    if (_isCardAnimating || _previewingOffer != null) return false;
    if (_cameraFollowing) return true;
    return _dotScreenOffset != null;
  }

  /// Where to draw the marker while the camera is parked, or null if we
  /// cannot say — off screen, or a tilted camera we refuse to guess at.
  Offset? get _dotScreenOffset {
    if (_cameraFollowing) return null; // centred, no projection needed
    final cam = _onlineCamState;
    final p = _pos;
    final size = _onlineMapSize;
    if (cam == null || p == null || size == null) return null;
    final c = cam.center.coordinates;
    final off = FlatMapProjection.screenOffsetFlat(
      target: p,
      cameraCenter: LatLng(c.lat.toDouble(), c.lng.toDouble()),
      zoom: cam.zoom,
      bearingDeg: cam.bearing,
      pitchDeg: cam.pitch,
      viewport: size,
    );
    if (off == null) return null;
    if (!FlatMapProjection.isOnScreen(off, size)) return null;
    return off;
  }
}
