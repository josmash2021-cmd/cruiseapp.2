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
  /// The iconSize the gold-dot annotation should carry right now.
  ///
  /// Three factors, one place: the first-appearance pop ([_dotPopScale]),
  /// the offer-preview shrink ([GoldLocationDot.offerMarkerScale]), and —
  /// when the high-resolution bitmap is the one in the image slot — the
  /// raster density, so the denser bitmap lands at the exact same
  /// on-screen size instead of three times it.
  double get _dotAnnotIconSize {
    final hiRes = _goldDot.currentBytesHiRes != null;
    return GoldLocationDot.driverAnnotationIconSize(
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      highRes: hiRes,
      scale: _dotPopScale * GoldLocationDot.offerMarkerScale.value,
    );
  }

  /// Shrink the driver badge toward the pickup/dropoff beads while an
  /// offer preview is on screen, and grow it back when the preview goes
  /// away — same level of detail across driver / pickup / dropoff.
  ///
  /// Called from [_clearAllAnnotations] because every preview entry and
  /// exit path funnels through it (tap, auto-trigger, dismiss, accept,
  /// reject, timeout) with `_previewingOffer` already set to the new
  /// state, so this one hook covers them all. The animation itself is
  /// idempotent — re-asserting the current target is a no-op.
  void _syncArrowScale() {
    final target =
        _previewingOffer != null ? GoldLocationDot.offerMarkerScaleSmall : 1.0;
    GoldLocationDot.animateOfferMarkerScale(
      this,
      target,
      // The overlay listens to the notifier itself; the Mapbox annotation
      // does not, so push each animated value into it.
      onFrame: () => _updateDriverAnnotation(),
    );
  }

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
      // Crisp bitmap when available: the classic 160-px frame at iconSize
      // 2.9 is a ~2.9× upscale — the "pixelated arrow" the driver saw the
      // moment an offer arrived and the annotation took over from the
      // vector overlay. Same artwork, same generated badge, more pixels.
      final dotImg = _goldDot.currentBytesHiRes ?? dotBytes;

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
          // Recreated under an offer preview (the preview cleared every
          // annotation on arrival): skip the 0→1.15 pop — the badge is
          // already mid-glide toward its offer size, and a bounce from
          // nothing on top of that glide reads as a glitch.
          if (!_dotPopDone && _previewingOffer != null) {
            _dotPopScale = GoldLocationDot.driverIconSize;
            _dotPopDone = true;
          }
          _goldDotAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
            geometry: mapbox.Point(
                coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),
            image: dotImg,
            iconSize: _dotAnnotIconSize,
            iconAnchor: mapbox.IconAnchor.CENTER,
            iconOffset: [0, 0],
            // The badge carries a heading arrow now, so it turns with the
            // driver — same _heading the nav car uses, already smoothed by
            // _motion (shortest-arc, low-passed).
            iconRotate: _heading,
            isDraggable: false,
            // Born hidden if the Flutter overlay is already drawing the
            // marker. Creation set no opacity, so a fresh annotation arrived
            // fully visible under an overlay painting the same arrow — two
            // arrows until something called this method again. The update
            // path below writes the opacity every time, so it did correct
            // itself, but only on the next tick: up to two seconds while the
            // driver is standing still and the watchdog is the only caller.
            iconOpacity: _overlayWantsMarker ? 0.0 : 1.0,
          ));
          _goldDotAnnotGen = _mapGeneration;
          _goldDotHidden = _overlayWantsMarker;
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
      final overlayWanted = _overlayWantsMarker;
      try {
        _goldDotAnnot!.geometry = mapbox.Point(
            coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude));
        _goldDotAnnot!.image = dotImg;
        // Invisible while the Flutter overlay is drawing the marker, or the
        // driver would see two: the smooth one and this one stepping behind
        // it. Kept alive and kept current rather than deleted, so the moment
        // they pan away it is already in the right place.
        _goldDotAnnot!.iconOpacity = overlayWanted ? 0.0 : 1.0;
        _goldDotAnnot!.iconSize = _dotAnnotIconSize;
        _goldDotAnnot!.iconRotate = _heading;
        _goldDotAnnot!.isDraggable = false;
      } catch (_) {
        // Annotation became invalid (rare). Null it so next tick recreates.
        _goldDotAnnot = null;
        _goldDotAnnotGen = 0;
        return;
      }

      // While the overlay owns the marker there is nothing to look at here,
      // so send one flush to hide it and then leave the channel alone — the
      // map itself is what needs that bandwidth at sixty frames a second.
      if (overlayWanted && _goldDotHidden) return;

      // Fire update() only when previous IPC finished. If busy, the geometry
      // write above already captured the latest position — no info lost,
      // because the finally of that in-flight call re-flushes us.
      if (_annotUpdateBusy) {
        _annotFlushPending = true;
        return;
      }
      _annotUpdateBusy = true;
      _diagAnnotUpdates++;
      try {
        await pointMgr.update(_goldDotAnnot!);
        // Latch ONLY after the flush lands (user report 2026-09-25, "el
        // botón de recentrar clona la flecha"): latching BEFORE it meant a
        // busy channel dropped the hide but kept the latch — every later
        // call early-returned, and the native arrow stayed visible, frozen
        // where it was, next to the overlay's live one.
        _goldDotHidden = overlayWanted;
      } catch (_) {
        // Delete before nulling: a transient failure must not orphan a
        // visible native annotation — the recreate path would stack a
        // second one on top of it.
        try {
          await pointMgr.delete(_goldDotAnnot!);
        } catch (_) {}
        _goldDotAnnot = null;
        _goldDotAnnotGen = 0;
        _goldDotHidden = false;
      } finally {
        _annotUpdateBusy = false;
        if (_annotFlushPending) {
          _annotFlushPending = false;
          unawaited(Future.microtask(_updateDriverAnnotation));
        }
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
            isDraggable: false,
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
        _carAnnot!.isDraggable = false;
      } catch (_) {
        _carAnnot = null;
        _carAnnotGen = 0;
        return;
      }

      if (_annotUpdateBusy) {
        _annotFlushPending = true;
        return;
      }
      _annotUpdateBusy = true;
      _diagAnnotUpdates++;
      try {
        await pointMgr.update(_carAnnot!);
      } catch (_) {
        // Same discipline as the dot above: delete before nulling so a
        // transient failure never orphans a visible native car.
        try {
          await pointMgr.delete(_carAnnot!);
        } catch (_) {}
        _carAnnot = null;
        _carAnnotGen = 0;
      } finally {
        _annotUpdateBusy = false;
        if (_annotFlushPending) {
          _annotFlushPending = false;
          unawaited(Future.microtask(_updateDriverAnnotation));
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
      annot.iconSize = _dotAnnotIconSize;
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

  /// Snap a raw GPS coordinate to the nearest point on the snap line.
  ///
  /// The line is the active route whenever one exists (offer preview,
  /// routeSummary, enRoute, inTrip — the old phase gate left preview and
  /// summary unsnapped, user report 2026-09-27); while searching there is
  /// no route, so the line is the matched polyline the RoadSnapService
  /// maintains from the driver's own trace. If that line is absent or not
  /// trusted, the real GPS keeps feeding SmoothMotion instead of freezing
  /// or jumping to a stale line; a later match rejoins with bounded motion.
  ///
  /// Hysteresis on the boundary, and continuity on the segment. The old flat
  /// 40 m in/out rule flickered: a fix at 39 m snapped to the lane, the next
  /// at 41 m fell back to raw GPS — the marker visibly hopped between the
  /// lane and the shoulder once per fix. Now the snap engages under 35 m and
  /// only releases past 55 m, and on parallel lanes the projection stays on
  /// the segment it was on unless another is clearly (8 m) closer — divided
  /// highways used to flip the marker between carriageways.
  LatLng _snapToRoute(LatLng raw) {
    final onRoute = _routePts.length >= 2;
    final pts = onRoute ? _routePts : _roadLinePts;
    if (_snapOnRouteSrc != onRoute) {
      _snapOnRouteSrc = onRoute;
      if (onRoute) {
        _roadLinePts = const [];
        _roadSnap.reset();
      }
    }
    final result = _roadLock.project(
      pts,
      raw,
      requireConfidence: !onRoute,
      speedMps: _motion.speedMps,
    );
    _roadLockBearing = result.trusted ? result.bearing : null;
    return driverDisplayPosition(result, raw);
  }

  /// The RoadSnapService found a better street line: swap the projection
  /// source (searching only — a live route always wins, and the service is
  /// reset the moment a route appears).
  void _onRoadSnapLine(List<LatLng> line) {
    if (!mounted || line.length < 2) return;
    _roadLinePts = line;
  }

  LatLng _snapRenderedToLine(LatLng p) {
    final onRoute = _routePts.length >= 2;
    final pts = onRoute ? _routePts : _roadLinePts;
    if (pts.length < 2 && _roadLock.lastPoint == null) return p;
    final result = _roadLock.project(
      pts,
      p,
      requireConfidence: !onRoute,
      speedMps: _motion.speedMps,
    );
    if (!result.trusted) return driverDisplayPosition(result, p);
    if (result.bearing != null && _motion.speedMps >= 1.0) {
      _motion.setBearing(result.bearing!);
    }
    _roadLockBearing = result.bearing;
    return driverDisplayPosition(result, p);
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
        // The active-trip line keeps its old weight — only the offer
        // preview was asked to go finer.
        lineWidth: 5.0,
        lineJoin: mapbox.LineJoin.ROUND,
      ));
    }
  }

  Future<void> _clearRouteAnnotation() async {
    // A reroute cross-fade in flight owns two lines and a timer that writes
    // both — stop it before deleting, or it keeps updating dead annotations.
    _rerouteFadeTimer?.cancel();
    _rerouteFadeTimer = null;
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

  /// Redraw the offer preview on a freshly created native surface.
  ///
  /// Everything the preview cinematic built belongs to the PlatformView
  /// that died with the old surface (app backgrounded → Android destroys
  /// the SurfaceView, or a coordinator revoke/acquire round trip). The
  /// State fields all survived — _previewingOffer, _fullSegOne/_fullSegTwo
  /// — so this puts back the final resting state instantly: both gold
  /// segments, both endpoint pins at their post-pop size, and the
  /// whole-route frame. Without it the driver came back from another app
  /// to the offer card with the route gone, and the default rebuild also
  /// flew the camera back to the driver at street zoom.
  Future<void> _restoreOfferPreviewOnFreshSurface() async {
    final offer = _previewingOffer;
    if (offer == null) return;
    final pickupLL = LatLng(
      _safeDouble(offer['pickup_lat']),
      _safeDouble(offer['pickup_lng']),
    );
    final dropoffLL = LatLng(
      _safeDouble(offer['dropoff_lat']),
      _safeDouble(offer['dropoff_lng']),
    );
    final driverPos = _pos ?? pickupLL;

    // Same gold, weight and join the gloss draw rests at.
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr != null) {
      final g1 = _fullSegOne.length >= 2 ? safeLineString(_fullSegOne) : null;
      if (g1 != null) {
        try {
          _previewPickupAnnot =
              await polyMgr.create(mapbox.PolylineAnnotationOptions(
            geometry: g1,
            lineColor: const Color(0xFFFFD700).toARGB32(),
            lineWidth: 4.0,
            lineJoin: mapbox.LineJoin.ROUND,
          ));
        } catch (_) {}
      }
      if (!mounted || _previewingOffer == null) {
        // Dismissed mid-restore: the reject clear already ran before g1
        // existed — take it back or it floats over "Finding trips".
        final stale = _previewPickupAnnot;
        _previewPickupAnnot = null;
        if (stale != null) {
          try {
            await polyMgr.delete(stale);
          } catch (_) {}
        }
        return;
      }
      final g2 = _fullSegTwo.length >= 2 ? safeLineString(_fullSegTwo) : null;
      if (g2 != null) {
        try {
          _previewDropoffAnnot =
              await polyMgr.create(mapbox.PolylineAnnotationOptions(
            geometry: g2,
            lineColor: const Color(0xFFFFD700).toARGB32(),
            lineWidth: 4.0,
            lineJoin: mapbox.LineJoin.ROUND,
          ));
        } catch (_) {}
      }
    }
    if (!mounted || _previewingOffer == null) return;

    // Endpoint pins at their post-pop size — the pop is an entrance
    // animation, not state worth replaying.
    final pointMgr = _pinAnnotMgr;
    if (pointMgr != null) {
      try {
        final imgs = await Future.wait([
          renderPickupRingBytes(
              size: kOfferEndpointSize, rasterScale: kEndpointRasterScale),
          renderDropoffRingDotBytes(
              size: kOfferEndpointSize, rasterScale: kEndpointRasterScale),
        ]);
        if (!mounted || _previewingOffer == null) return;
        _prevPickupAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(
              coordinates:
                  mapbox.Position(pickupLL.longitude, pickupLL.latitude)),
          image: imgs[0],
          iconSize: 1 / kEndpointRasterScale,
          iconAnchor: mapbox.IconAnchor.CENTER,
        ));
        _prevDropoffAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(
              coordinates:
                  mapbox.Position(dropoffLL.longitude, dropoffLL.latitude)),
          image: imgs[1],
          iconSize: 1 / kEndpointRasterScale,
          iconAnchor: mapbox.IconAnchor.CENTER,
        ));
        final stopLL = _offerStopPoint(offer);
        if (stopLL != null) {
          _prevStopAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
            geometry: mapbox.Point(
                coordinates:
                    mapbox.Position(stopLL.longitude, stopLL.latitude)),
            image: imgs[1],
            iconSize: 1 / kEndpointRasterScale,
            iconAnchor: mapbox.IconAnchor.CENTER,
          ));
        }
      } catch (_) {}
    }
    if (!mounted || _previewingOffer == null) {
      // Same dismiss-mid-restore hole as g1 above, for the pins.
      unawaited(_clearPickupDropoffAnnotations().catchError((_) {}));
      return;
    }

    // A recreated surface boots centered on the driver at street zoom —
    // reframe the whole route or the lines just drawn sit off-screen.
    await _fitBoundsMulti(_routeFramePoints(driverPos, pickupLL, dropoffLL,
        stopLL: _offerStopPoint(offer)));
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
      _prevDropoffAnnot,
      _prevStopAnnot,
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
    _prevStopAnnot = null;
  }

  Future<void> _clearAllAnnotations() async {
    _isClearingAnnotations = true;
    // Every preview entry/exit funnels through here with _previewingOffer
    // already at its new value — the one place that starts the badge's
    // shrink/grow glide and refreshes the spotlight for the new state.
    _syncArrowScale();
    unawaited(_syncZoneLayers());
    try {
      // Web overlays live in the GL JS controller, not in annotation
      // managers — clear them by the ids the preview draws with.
      if (kIsWeb) {
        final web = _webMap;
        if (web != null) {
          web.removePolyline('offerSegOne');
          web.removePolyline('offerSegTwo');
          web.removeMarker('offerPickup');
          web.removeMarker('offerDropoff');
          web.removeMarker('offerStop');
          web.removeCircle('driverPos');
        }
      }
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

  /// Self-healing sweep (user report: "queda la ruta dibujada de la oferta
  /// pasada / cuando se rechaza queda dibujada"): every dismiss path already
  /// funnels through [_clearAllAnnotations], but the preview is a multi-await
  /// cinematic and a handle created mid-flight can land AFTER its clear ran.
  /// When no preview is open, no preview annotation may exist — delete any
  /// survivor instead of hoping every async path cleaned up. Called from the
  /// offer heartbeat (_applyOffers) and after reject; free when clean.
  Future<void> _sweepPreviewOrphans() async {
    if (_isClearingAnnotations) return;
    if (_previewingOffer != null || _isCardAnimating) return;
    if (_routeAnnot == null &&
        _previewPickupAnnot == null &&
        _previewDropoffAnnot == null &&
        _prevPickupAnnot == null &&
        _prevDropoffAnnot == null &&
        _prevStopAnnot == null) {
      return;
    }
    debugPrint('[OfferRoute] sweep: orphan preview annotations removed '
        '(route=${_routeAnnot != null} seg1=${_previewPickupAnnot != null} '
        'seg2=${_previewDropoffAnnot != null} pins='
        '${_prevPickupAnnot != null || _prevDropoffAnnot != null} '
        'stop=${_prevStopAnnot != null})');
    try {
      await _clearAllAnnotations();
    } catch (e) {
      debugPrint('[OfferRoute] sweep clear failed: $e');
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

  /// Copy [seg] with its first point replaced by [first] and its last by
  /// [last], so the drawn line touches the markers exactly instead of the
  /// road-snapped points the router returned. Never mutates the input —
  /// cached segment lists are shared.
  ///
  /// An empty [seg] stays empty: returning `[first, last]` here would
  /// resurrect the straight-across-blocks line the fetch layer just refused
  /// to draw.
  List<LatLng> _anchoredEndpoints(List<LatLng> seg, LatLng first, LatLng last) {
    if (seg.isEmpty) return const [];
    final out = List<LatLng>.of(seg);
    out[0] = first;
    out[out.length - 1] = last;
    return out;
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
    LatLng dropoffLL, {
    LatLng? stopLL,
  }) {
    final pts = <LatLng>[
      driverPos,
      pickupLL,
      if (stopLL != null) stopLL,
      dropoffLL,
    ];
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
    if (points.isEmpty) return;
    final botPad = MediaQuery.of(context).padding.bottom;
    final topPad = MediaQuery.of(context).padding.top;
    final hasCard = _pendingOffers.isNotEmpty || _previewingOffer != null;
    // The card's real height plus its header, so the route is framed in
    // the strip of map that is actually visible above it. 340 was a guess
    // from when the card was shorter.
    //
    // The header is the drag handle + "N Viaje(s) disponible(s)" row, the
    // dots row appears when more than one offer is stacked, and botPad is
    // the full system-nav inset the card itself now clears on Android.
    // Reserve what the column really occupies: less, and the framed pickup
    // pin lands behind the header text (the overlap in the offer photo).
    var cardArea = hasCard
        ? _currentOfferCardHeight(context) +
            56.0 +
            botPad +
            (_pendingOffers.length > 1 ? 18.0 : 0.0)
        : 60.0;
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
    //
    // The trim eats the top allowance first: shaving the card reservation
    // frames content where the card actually is, which is exactly the
    // pin-under-the-header overlap this padding exists to prevent. The
    // card area only gives once the top is down to its minimum — a phone
    // so short the card genuinely cannot fit any other way.
    final screenH = MediaQuery.of(context).size.height;
    final maxInsets = screenH * 0.65;
    if (topArea + cardArea > maxInsets) {
      final excess = topArea + cardArea - maxInsets;
      final minTop = topPad + 30.0;
      final topCut = math.min(excess, math.max(0.0, topArea - minTop));
      topArea -= topCut;
      final remaining = excess - topCut;
      if (remaining > 0) cardArea -= remaining;
      debugPrint('[OfferRoute] insets trimmed to fit a ${screenH.round()}pt '
          'screen: top=${topArea.round()} bottom=${cardArea.round()}');
    }
    // Web: the same frame, one GL JS call. No tilt/bearing to preserve —
    // the browser preview never tips the camera.
    if (kIsWeb) {
      _webMap?.fitBounds(
        [for (final p in points) (lng: p.longitude, lat: p.latitude)],
        paddingTop: topArea,
        paddingLeft: 60,
        paddingBottom: cardArea,
        paddingRight: 60,
        durationMs: 700,
      );
      return;
    }
    if (_map == null) return;
    final coords = points
        .map((p) =>
            mapbox.Point(coordinates: mapbox.Position(p.longitude, p.latitude)))
        .toList();
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
      // A pickup one or two blocks away would frame at street level (17+),
      // a zoom the offer card never needs — cap it at the cruise zoom.
      if ((cam.zoom ?? 15.5) > 15.5) cam.zoom = 15.5;
      if (mounted) {
        await _map?.flyTo(cam, mapbox.MapAnimationOptions(duration: 700));
      }
    } catch (e) {
      debugPrint('[DriverOnline] _fitBoundsMulti error: $e');
    }
  }

  /// Keep the offer preview honest while the driver rolls: refetch the
  /// driver→pickup leg once the driver is 30 m from the last anchor, at
  /// most every 10 seconds. The line shortens behind them, a different
  /// road choice comes back as a fresh routed line, and the card's
  /// min/miles drop from the same fetch. The camera is NOT reframed —
  /// the driver moving is not a reason to move their map.
  Future<void> _maybeRefreshOfferRoutePreview(LatLng newLL) async {
    final offer = _previewingOffer;
    if (offer == null || _offerRouteFetchBusy) return;
    final anchor = _offerRouteAnchor;
    if (anchor != null && _hav(anchor, newLL) < 0.03) return;
    if (DateTime.now().difference(_lastOfferRouteFetch).inSeconds < 10) {
      return;
    }
    _offerRouteFetchBusy = true;
    _lastOfferRouteFetch = DateTime.now();
    try {
      final pickupLL = LatLng(
        _safeDouble(offer['pickup_lat']),
        _safeDouble(offer['pickup_lng']),
      );
      final seg = await _fetchRouteWithMetrics(newLL, pickupLL);
      if (!mounted || _previewingOffer == null || seg.pts.length < 2) return;
      _offerRouteAnchor = newLL;
      // Anchor the start under the driver's arrow — the router snaps the
      // origin to the road, the same stub the initial draw fixes.
      _fullSegOne = _anchoredEndpoints(seg.pts, newLL, pickupLL);

      // The card reads its "X min (Y mi) away" from this cache — refresh
      // the driver leg's metrics in place so the numbers drop as the
      // driver rolls. The pickup→dropoff leg does not change.
      final oid = (offer['offer_id'] ?? offer['id'] ?? '').toString();
      final cached = _routeCache[oid];
      if (cached != null) {
        _routeCache[oid] = _CachedOfferRoute(
          segOne: seg.pts,
          segTwo: cached.segTwo,
          cachedAt: cached.cachedAt,
          dropoffPlaceType: cached.dropoffPlaceType,
          pickupPin: cached.pickupPin,
          dropoffPin: cached.dropoffPin,
          driverToPickupMin: seg.durSec != null ? seg.durSec! / 60.0 : null,
          driverToPickupKm: seg.distM != null ? seg.distM! / 1000.0 : null,
          pickupToDropoffMin: cached.pickupToDropoffMin,
          pickupToDropoffKm: cached.pickupToDropoffKm,
        );
      }

      if (kIsWeb) {
        _webMap?.setPolyline(
          'offerSegOne',
          [for (final p in _fullSegOne) (lng: p.longitude, lat: p.latitude)],
          color: '#FFD700',
          width: 4,
        );
      } else {
        // Instant geometry swap — the cinematic draw is for the offer's
        // arrival, not for every GPS fix.
        final annot = _previewPickupAnnot;
        final polyMgr = _polylineAnnotMgr;
        final safeGeom = safeLineString(_fullSegOne);
        if (annot != null && polyMgr != null && safeGeom != null) {
          annot.geometry = safeGeom;
          try {
            await polyMgr.update(annot);
          } catch (_) {}
        } else if (annot == null && polyMgr != null && safeGeom != null) {
          // The initial gloss draw was skipped (route fetch failed when the
          // offer arrived, so there was nothing to draw). This refresh just
          // fetched real geometry — update-only would silently drop it and
          // the preview would stay lineless despite the successful fetch.
          try {
            final created =
                await polyMgr.create(mapbox.PolylineAnnotationOptions(
              geometry: safeGeom,
              lineColor: const Color(0xFFFFD700).toARGB32(),
              lineWidth: 4.0,
              lineJoin: mapbox.LineJoin.ROUND,
            ));
            if (_previewingOffer != null && mounted) {
              _previewPickupAnnot = created;
            } else {
              // Preview dismissed while create() was in flight.
              try {
                await polyMgr.delete(created);
              } catch (_) {}
            }
          } catch (_) {}
        }
      }
      _setState(() {});
    } finally {
      _offerRouteFetchBusy = false;
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingOffers.isEmpty || _isCardAnimating) {
        // The latch arms only when the trigger actually RUNS (user report:
        // "cuando recibe una oferta queda la ruta de la oferta pasada") —
        // armed-before-the-guard meant a skipped trigger never retried, so
        // the new offer's route never drew and the old one stayed.
        debugPrint('[OfferRoute] auto-trigger skipped for $oid — '
            'mounted=$mounted offers=${_pendingOffers.length} '
            'animating=$_isCardAnimating');
        return;
      }
      _lastAutoTriggeredOfferId = oid;
      _onOfferCardTap(offer);
    });
  }

  // ── Cinematic offer card tap → full animation sequence ──
  Future<void> _onOfferCardTap(Map<String, dynamic> offer) async {
    if (_isCardAnimating) return;
    // The latch can never stay on (user report: "queda la ruta dibujada de
    // la oferta pasada"): a throw mid-sequence used to leave
    // _isCardAnimating true forever, every later offer's auto-preview was
    // vetoed by it, and the OLD route stayed on the map under the NEW card.
    _isCardAnimating = true;
    try {
      await _offerCardTapSequence(offer);
    } finally {
      _isCardAnimating = false;
    }
  }

  // Sequence: fit bounds → pins fade+pop → draw seg1 (driver→pickup)
  //   → pickup pin popup → draw seg2 (pickup→dropoff) → dropoff pin popup → refit
  // Runs once per tap — no loops, no repeats.
  Future<void> _offerCardTapSequence(Map<String, dynamic> offer) async {
    final oid = (offer['offer_id'] ?? offer['id'] ?? '').toString();

    final pickupLat = _safeDouble(offer['pickup_lat']);
    final pickupLng = _safeDouble(offer['pickup_lng']);
    final dropoffLat = _safeDouble(offer['dropoff_lat']);
    final dropoffLng = _safeDouble(offer['dropoff_lng']);
    final pickupLL = LatLng(pickupLat, pickupLng);
    final dropoffLL = LatLng(dropoffLat, dropoffLng);
    final driverPos = _pos ?? pickupLL; // fallback when GPS hasn't resolved yet
    // A booking-time stop turns seg2 into pickup → stop → dropoff, one
    // continuous line, and gets the dropoff pin (user spec).
    final stopLL = _offerStopPoint(offer);
    final segTwoVia = stopLL == null ? null : [stopLL];

    _setState(() {
      _previewingOffer = offer;
      _animatingOfferId = oid;
      _tappedCardIds.add(oid);
    });
    // Live-refresh baseline: the driver leg refetches only once the driver
    // has rolled 30 m from here, and no more than every 10 seconds.
    _offerRouteAnchor = driverPos;
    _lastOfferRouteFetch = DateTime.now();

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
        _fetchRoutePoints(pickupLL, dropoffLL, waypoints: segTwoVia),
      ]);
      _fullSegOne = routeFutures[0];
      _fullSegTwo = routeFutures[1];
    }
    debugPrint('[OfferRoute] $oid segments: '
        '${_fullSegOne.length} + ${_fullSegTwo.length} points'
        '${cached != null ? " (cached)" : ""}');

    // Anchor both ends exactly: routing snaps the origin/destination to the
    // nearest road, which can leave a visible stub of street between a
    // marker and the line's end. The line must begin under the driver's
    // arrow and end under the dropoff ring. Copies — the cache's lists are
    // shared and must not be mutated.
    _fullSegOne = _anchoredEndpoints(_fullSegOne, driverPos, pickupLL);
    _fullSegTwo = _anchoredEndpoints(_fullSegTwo, pickupLL, dropoffLL);
    if (!mounted || _previewingOffer == null) {
      _isCardAnimating = false;
      return;
    }

    // Web: no annotation managers exist on GL JS — the cinematic phases
    // below would run against null managers and draw nothing. The browser
    // gets the same result in one pass: frame, both segments, both pins.
    if (kIsWeb) {
      await _previewOfferRouteWeb(driverPos, pickupLL, dropoffLL,
          stopLL: stopLL);
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
    await _fitBoundsMulti(
        _routeFramePoints(driverPos, pickupLL, dropoffLL, stopLL: stopLL));
    if (!mounted || _previewingOffer == null) {
      _isCardAnimating = false;
      return;
    }

    // ── PHASE 2: Create pins at size 0 (invisible) ──
    // A hollow gold ring for the pickup and a white ring with a solid dot
    // for the dropoff — this page's pair, inverted from the rider receipt
    // by request. The cached pins are ignored on purpose: they hold
    // the old teardrop pins, and mixing the two would give the driver a
    // different marker depending on whether the route had been fetched.
    //
    // Rendered at kEndpointRasterScale× the pixels and shown at
    // 1/kEndpointRasterScale the iconSize (see _animateSinglePinPop):
    // the same size on screen, but a ~1:1 bitmap on a 3× Android phone
    // instead of the fuzzy 3× upscale the 55 px render produced.
    final pinResults = await Future.wait([
      renderPickupRingBytes(
          size: kOfferEndpointSize, rasterScale: kEndpointRasterScale),
      renderDropoffRingDotBytes(
          size: kOfferEndpointSize, rasterScale: kEndpointRasterScale),
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
      // The stop pin sits BETWEEN the two endpoints in the pop cascade
      // (phase 7) — same dropoff ring-dot bitmap.
      if (stopLL != null) {
        _prevStopAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(
              coordinates: mapbox.Position(stopLL.longitude, stopLL.latitude)),
          image: dropoffPinImg,
          iconSize: 0.01,
          iconAnchor: mapbox.IconAnchor.CENTER,
        ));
      }
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
      // Dismissed while the endpoint pins were being created above: the
      // reject/expire clear ran BEFORE they existed, so it had no handle
      // to them — take them back here or they float over "Finding trips"
      // with no card to explain them. From this guard on, every dismiss
      // path's own clear reaches them (they are tracked), so this is the
      // only bail that needs the sweep.
      unawaited(_clearPickupDropoffAnnotations().catchError((_) {}));
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
    await _animateSinglePinPop(_prevPickupAnnot,
        targetScale: 1 / kEndpointRasterScale);
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

    // ── PHASE 7: Dropoff pin popup (stop first — the cascade follows the
    // ride's order: pickup, stop, dropoff) ──
    await _animateSinglePinPop(_prevStopAnnot,
        targetScale: 1 / kEndpointRasterScale);
    await _animateSinglePinPop(_prevDropoffAnnot,
        targetScale: 1 / kEndpointRasterScale);
    if (!mounted || _previewingOffer == null) {
      _isCardAnimating = false;
      return;
    }

    // ── PHASE 8: Refit with the full route shape ──
    _fitBoundsMulti(
        _routeFramePoints(driverPos, pickupLL, dropoffLL, stopLL: stopLL));

    if (mounted && _previewingOffer != null) {
      _setState(() => _offerRouteShown = true);
    }
    _isCardAnimating = false;
  }

  /// Web route preview: GL JS draws the whole thing in one pass — there
  /// are no annotation managers to feed progressively, so the cinematic
  /// phases of the native path collapse into frame → draw → pins.
  Future<void> _previewOfferRouteWeb(
    LatLng driverPos,
    LatLng pickupLL,
    LatLng dropoffLL, {
    LatLng? stopLL,
  }) async {
    final web = _webMap;
    if (web == null) {
      debugPrint('[OfferRoute] web preview skipped — no controller yet');
      return;
    }
    await _fitBoundsMulti(
        _routeFramePoints(driverPos, pickupLL, dropoffLL, stopLL: stopLL));
    if (!mounted || _previewingOffer == null) return;

    List<LngLatPoint> lngLats(List<LatLng> seg) =>
        [for (final p in seg) (lng: p.longitude, lat: p.latitude)];
    void drawSegments(WebMapController w) {
      if (_fullSegOne.length >= 2) {
        w.setPolyline('offerSegOne', lngLats(_fullSegOne),
            color: '#FFD700', width: 4);
      }
      if (_fullSegTwo.length >= 2) {
        w.setPolyline('offerSegTwo', lngLats(_fullSegTwo),
            color: '#FFD700', width: 4);
      }
    }

    drawSegments(web);
    final midOne = _fullSegOne.isNotEmpty
        ? _fullSegOne[_fullSegOne.length ~/ 2]
        : driverPos;
    debugPrint('[OfferRoute] web draw: '
        'seg1=${_fullSegOne.length} seg2=${_fullSegTwo.length} points, '
        'layer=${web.hasLayer('cruise-polyline-offerSegOne')}, '
        'painted=${web.renderedFeatureCount('cruise-polyline-offerSegOne', midOne.longitude, midOne.latitude)}');
    // Re-assert the lines over the next seconds: if the style finished
    // loading late, or anything wiped runtime layers after the draw, the
    // first pass is gone and the card gives no second chance.
    for (final delayMs in const [900, 2500]) {
      Future.delayed(Duration(milliseconds: delayMs), () {
        if (!mounted || _previewingOffer == null) return;
        final w = _webMap;
        if (w == null) return;
        drawSegments(w);
        debugPrint('[OfferRoute] web re-assert ($delayMs ms): '
            'layer=${w.hasLayer('cruise-polyline-offerSegOne')}, '
            'painted=${w.renderedFeatureCount('cruise-polyline-offerSegOne', midOne.longitude, midOne.latitude)}');
      });
    }

    // The driver is one end of this route — the Flutter overlay arrow
    // marks it, projected at the driver's pixel, the same arrow the rest
    // of the app draws on this same map.

    // The same pair as the native preview: hollow gold ring for the
    // pickup, white ring with a solid dot for the dropoff.
    final pinResults = await Future.wait([
      renderPickupRingBytes(size: kOfferEndpointSize),
      renderDropoffRingDotBytes(size: kOfferEndpointSize),
    ]);
    if (!mounted || _previewingOffer == null) return;
    web.addMarker('offerPickup', pickupLL.longitude, pickupLL.latitude,
        iconBytes: pinResults[0]);
    web.addMarker('offerDropoff', dropoffLL.longitude, dropoffLL.latitude,
        iconBytes: pinResults[1]);
    // The stop wears the dropoff ring-dot too (user spec).
    if (stopLL != null) {
      web.addMarker('offerStop', stopLL.longitude, stopLL.latitude,
          iconBytes: pinResults[1]);
    }
    _setState(() => _offerRouteShown = true);
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
  ///
  /// [targetScale] is the iconSize the spring settles on: 1.0 for a
  /// standard-density bitmap, 1/kEndpointRasterScale for a hi-res one, so
  /// the denser render lands at the same on-screen size instead of 3× it.
  Future<void> _animateSinglePinPop(mapbox.PointAnnotation? annot,
      {double targetScale = 1.0}) async {
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
      final scale = _springScale(progress) * targetScale;
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
        lineWidth: 4.0,
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
    // Track the handle NOW, not at progress 1.0. The cleanup contract used
    // to be "the ticker deletes the half-drawn line itself when it notices
    // the preview is gone" — but anything that kills the ticker before that
    // frame runs (_closePreview disposes it, the 8s timeout in
    // _onOfferCardTap letting PHASE 6 stop/dispose a seg1 ticker frozen by
    // an iOS background) left the line with no handle at all, and no clear
    // on reject/expire could reach it: the gold route stayed painted with
    // the offer card already gone.
    _previewPickupAnnot = mainLine;

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
        // Take the half-drawn line back with it. Belt-and-suspenders: the
        // handle is already tracked from creation (see above), so the clear
        // on reject/expire reaches it even if this frame never runs — this
        // delete covers the window where the clear already ran before the
        // handle was assigned.
        final stale = mainLine;
        if (stale != null) {
          polyMgr.delete(stale).catchError((_) {});
        }
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
          // catchError like every other call here: the handle may already
          // be natively deleted (clear beat the ticker to it), and an
          // unawaited rejection is an unhandled async error.
          polyMgr.update(ml).catchError((_) {});
        }
        // Handle already tracked since creation — nothing to assign here.
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
        lineWidth: 4.0,
        lineJoin: mapbox.LineJoin.ROUND,
      ));
    } catch (_) {}
    if (!mounted || seg2Line == null) return;
    // Same early tracking as seg1: a ticker killed before its first frame
    // (_closePreview disposes it, an iOS background freeze + the 8s draw
    // timeout) must not orphan the half-drawn line — the reject/expire
    // clear only reaches annotations reachable through the State fields.
    _previewDropoffAnnot = seg2Line;

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
          polyMgr.update(sl).catchError((_) {});
        }
        // Handle already tracked since creation — nothing to assign here.
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

  /// Fetch route points from Google Directions → OSRM → Mapbox, retried once
  /// after a short backoff.
  ///
  /// Returns an EMPTY list when every provider fails — the straight-line
  /// fallback was removed. That line cut across blocks and lied to the
  /// driver (it is the line in the bug-report photo); no line at all is the
  /// honest failure. Callers keep the pickup/dropoff markers either way.
  /// The booking-time stop as a point, parsed from the offer's `stops`
  /// field — a JSON string from the server payloads, or an already-decoded
  /// list. Null when the ride has no stop.
  LatLng? _offerStopPoint(Map<String, dynamic> offer) {
    return parseTripStop(offer)?.point;
  }

  /// The stop's display label ("Stop" row on the offer card).
  String? _offerStopLabel(Map<String, dynamic> offer) {
    return parseTripStop(offer)?.label;
  }

  Future<List<LatLng>> _fetchRoutePoints(LatLng o, LatLng d,
      {List<LatLng>? waypoints}) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future.delayed(const Duration(milliseconds: 600));
        if (!mounted) break;
      }
      final pts = await _fetchRoutePointsOnce(o, d, waypoints: waypoints);
      if (pts.length >= 2) return pts;
    }
    debugPrint('[OfferRoute] all providers failed — no route line drawn');
    return const [];
  }

  /// One pass over the providers: Google → OSRM → Mapbox.
  Future<List<LatLng>> _fetchRoutePointsOnce(LatLng o, LatLng d,
      {List<LatLng>? waypoints}) async {
    final via = (waypoints == null || waypoints.isEmpty)
        ? null
        : waypoints.map((p) => '${p.latitude},${p.longitude}').join('|');
    final chain = [o, ...?waypoints, d]
        .map((p) => '${p.longitude},${p.latitude}')
        .join(';');
    List<LatLng>? pts;
    // Google Directions API
    try {
      final uri =
          Uri.https('maps.googleapis.com', '/maps/api/directions/json', {
        'origin': '${o.latitude},${o.longitude}',
        'destination': '${d.latitude},${d.longitude}',
        'key': ApiKeys.webServices,
        'mode': 'driving',
        if (via != null) 'waypoints': via,
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
        final path = '/route/v1/driving/$chain';
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
          '$chain'
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
    // No straight-line fallback: an empty list means "no route line" — the
    // markers still draw. See _fetchRoutePoints.
    return pts ?? const [];
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
      _animateToPosition(_pos!, zoom: 15.5, bearing: _smoothedBearing, tilt: 0);
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

  /// The plugin exposes no onRotateListener (2.20), so a two-finger twist
  /// is only observable as the camera's bearing diverging from the value
  /// the follow ticker last wrote. Divergence beyond ~4° releases follow
  /// only with two fingers present, so a delayed chase write cannot be
  /// mistaken for a gesture. Programmatic flights use [_camFlightUntil].
  void _maybeUnlatchOnManualRotate(mapbox.CameraState cam) {
    if (!_cameraFollowing || _previewingOffer != null) return;
    if (_mapPointers < 2) return;
    if (DateTime.now().isBefore(_camFlightUntil)) return;
    final written = _lastCamWriteBearing;
    if (written == null) return;
    var diff = (cam.bearing - written).abs() % 360;
    if (diff > 180) diff = 360 - diff;
    if (diff > 4) _onCameraMoveStarted();
  }

  /// Called when a camera movement is initiated by user gesture.
  /// Pauses auto-follow so the driver can freely explore the map.
  ///
  /// Applies in every phase now. It used to return early unless the driver
  /// was navigating, so while merely online the camera re-centred on them
  /// sixty times a second — the map fought the finger and sprang back the
  /// instant they let go.
  ///
  /// The marker stays a vector overlay projected from the real coordinates
  /// on every rendered frame. The pointer guard releases follow before the
  /// next chase write, so the map moves under the finger instead of fighting
  /// it. Only the manual recenter re-engages it.
  void _onCameraMoveStarted() {
    if (_mapPointers == 0 && DateTime.now().isBefore(_camFlightUntil)) {
      _phantomGestureEvents++;
      return;
    }
    _cameraActionGate.begin();
    _recenterLanding = null;
    // ONE arrow, always (user report 2026-10-10: "que la flecha sea la misma
    // cuando hace zoom o mueve el mapa que cuando está normal" — size jump,
    // wrong heading and a double-arrow flicker on every gesture). The overlay
    // no longer steps aside for the native annotation mid-drag: the camera
    // arrives per rendered frame in onCameraChangeListener (_onlineCamState)
    // and the overlay projects from it locally, so the SAME vector arrow
    // stays glued to the driver's lat/lng through the gesture — like the
    // ride-request pin labels, which glue per frame with zero IPC. The
    // annotation keeps exactly one job: the offer-preview programmatic
    // flight (_isCardAnimating), where events trail the flyTo.
    _markerFrame.value++;
    _updateDriverAnnotation();
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
  void _maybeCompleteRecenter(mapbox.CameraState cam) {
    final guard = _recenterLanding;
    if (guard == null) return;
    if (!_cameraActionGate.isCurrent(guard.sequence)) {
      _recenterLanding = null;
      return;
    }
    final center = cam.center.coordinates;
    final cameraPoint = LatLng(center.lat.toDouble(), center.lng.toDouble());
    if (!guard.isLanding(_cameraActionGate, cameraPoint)) return;
    _recenterLanding = null;
    if (!mounted) return;
    _setState(() => _cameraFollowing = true);
    _updateDriverAnnotation();
    ApiService.logClientEvent(
        'recenter_settle', 'landed=true phantoms=$_phantomGestureEvents');
  }

  Future<void> _recenterWithFollow({
    required double zoom,
    required double bearing,
    required double tilt,
  }) async {
    final seq = _cameraActionGate.begin();
    final pos = _pos;
    if (pos == null) {
      ApiService.logClientEvent('recenter_fired', 'no_position');
      if (mounted) _setState(() => _cameraFollowing = true);
      return;
    }
    if (_cameraFollowing) _setState(() => _cameraFollowing = false);
    _recenterLanding = RecenterLandingGuard(seq, pos);
    _pendingCamWrite = null;
    _zoomEaseDone = true;
    _cameraBearing = bearing;
    final options = mapbox.CameraOptions(
      center: mapbox.Point(
          coordinates: mapbox.Position(pos.longitude, pos.latitude)),
      zoom: zoom,
      bearing: bearing,
      pitch: tilt,
      padding: _kZeroCamPadding,
    );
    _camFlightUntil = DateTime.now()
        .add(const Duration(milliseconds: _kRecenterFlightMs + 320));
    var issued = false;
    var landed = false;
    if (kIsWeb) {
      final web = _webMap;
      issued = web != null;
      if (web != null) {
        web.flyTo(
          lng: pos.longitude,
          lat: pos.latitude,
          zoom: zoom,
          bearing: bearing,
          pitch: tilt,
          durationMs: _kRecenterFlightMs,
        );
        landed = true;
      }
    } else {
      final map = _map;
      if (mounted && _mapMounted && map != null) {
        issued = true;
        try {
          await map
              .flyTo(options,
                  mapbox.MapAnimationOptions(duration: _kRecenterFlightMs))
              .timeout(const Duration(milliseconds: _kRecenterFlightMs + 2000));
          landed = true;
        } catch (e) {
          debugPrint('[DriverOnline] recenter flyTo failed: $e');
        }
        if (!mounted || !_cameraActionGate.isCurrent(seq)) return;
        if (!landed && _mapMounted && identical(map, _map)) {
          try {
            await map.setCamera(options).timeout(const Duration(seconds: 2));
            landed = true;
          } catch (e) {
            debugPrint('[DriverOnline] recenter fallback failed: $e');
            ApiService.logClientEvent('recenter_settle_write', 'failed=$e');
          }
        }
      }
    }
    if (!mounted || !_cameraActionGate.isCurrent(seq)) return;
    ApiService.logClientEvent('recenter_fired', '$issued');
    if (kIsWeb && landed) {
      _recenterLanding = null;
      _setState(() => _cameraFollowing = true);
      _updateDriverAnnotation();
      return;
    }
    final cam = _onlineCamState;
    if (cam != null) _maybeCompleteRecenter(cam);
    if (!issued) {
      _recenterLanding = null;
      _setState(() => _cameraFollowing = true);
      _updateDriverAnnotation();
    }
  }

  void _recenterCamera() {
    if (!mounted) return;
    ApiService.logClientEvent('recenter_tap',
        'online=$_driverOnline phase=$_phase hasPos=${_pos != null} mapMounted=$_mapMounted hasMap=${_map != null}');
    _phantomGestureEvents = 0;
    if (_previewingOffer != null) return;
    if (_phase == _Phase.searching &&
        FeatureFlags.zonesMapEnabled &&
        !_driverOnline) {
      ApiService.logClientEvent('recenter_fit', 'scope=arrow_zone_zoom');
      unawaited(_recenterArrowZoneZoom());
      return;
    }
    final bearing = _smoothedBearing;
    final isNav = _phase == _Phase.enRouteToPickup ||
        _phase == _Phase.inTrip ||
        _phase == _Phase.routeSummary;
    unawaited(_recenterWithFollow(
      zoom: isNav ? 17.5 : 15.5,
      bearing: bearing,
      tilt: isNav ? 55 : 0,
    ));
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
    if (kIsWeb) return _overlayWantsMarker;
    if (_goldDotAnnot != null && !_goldDotHidden) return false;
    return _overlayWantsMarker;
  }

  bool get _overlayWantsMarker {
    if (_pos == null) return false;
    // Web: one arrow for the whole app — this same Flutter overlay, placed
    // at the driver's projected pixel on this same map. While the preview
    // frames the route the driver is on screen by construction; if a pan
    // pushes them off, hide rather than draw somewhere wrong.
    if (kIsWeb) {
      if (_previewingOffer != null) return _dotScreenOffset != null;
      return true;
    }
    // Nothing else is drawing it, so we do — but only while following
    // (centred is then correct by construction). Not following with no
    // annotation and no projection means we cannot say where the driver is
    // on screen: draw NOTHING (user report 2026-09-26: "la flecha se queda
    // en el medio de la pantalla así se arrastre") — a centred arrow over a
    // panned map points at a street the driver is not on. The annotation
    // watchdog recreates the native marker within seconds.
    if (_goldDotAnnot == null) return _cameraFollowing;
    // An offer preview flies the camera around the route, and while it is
    // flying the annotation wins: the overlay is positioned from
    // camera-change events, which arrive over the same channel we are
    // avoiding — during an animation they lag, and a marker that lags a
    // moving camera slides across the map. Once the camera lands the
    // trade flips: the overlay draws the very same arrow as a vector,
    // where the annotation was its 160-px bitmap scaled up ~2.4× — the
    // pixelated photo the driver reported.
    if (_isCardAnimating) return false;
    if (_cameraFollowing && _previewingOffer == null) return true;
    return _dotScreenOffset != null;
  }

  /// The camera padding shifts where the camera centre actually renders:
  /// Mapbox centres the frame INSIDE the padded viewport, so every overlay
  /// pixel from the flat projection moves by half the inset imbalance
  /// (user report 2026-10-16: tras el recenter offline la flecha y las
  /// píldoras de zona quedaban corridas — la cámara traía el padding del
  /// sheet y la proyección lo ignoraba).
  Offset _camPadShift(mapbox.CameraState cam) {
    final p = cam.padding;
    return Offset((p.left - p.right) / 2, (p.top - p.bottom) / 2);
  }

  /// Where to draw the marker while the camera is parked, or null if we
  /// cannot say — off screen, or a tilted camera we refuse to guess at.
  Offset? get _dotScreenOffset {
    if (kIsWeb) {
      // GL JS projects into the map container's own pixel space — the same
      // box this overlay is drawn in, so the arrow lands on the driver's
      // real pixel whether the camera follows them or is framing a route.
      final p = _pos;
      final web = _webMap;
      final size = _onlineMapSize;
      if (p == null || web == null || size == null) return null;
      final off = web.pixelForCoordinate(p.longitude, p.latitude);
      if (!off.dx.isFinite || !off.dy.isFinite) return null;
      if (off.dx < 0 ||
          off.dy < 0 ||
          off.dx > size.width ||
          off.dy > size.height) {
        return null;
      }
      return off;
    }
    final cam = _onlineCamState;
    final p = _pos;
    final size = _onlineMapSize;
    if (cam == null || p == null || size == null) return null;
    if (_cameraFollowing && _previewingOffer == null) {
      return Offset(size.width / 2, size.height / 2) + _camPadShift(cam);
    }
    final c = cam.center.coordinates;
    final off = FlatMapProjection.screenOffsetHeading(
      target: p,
      cameraCenter: LatLng(c.lat.toDouble(), c.lng.toDouble()),
      zoom: cam.zoom,
      bearingDeg: cam.bearing,
      pitchDeg: cam.pitch,
      viewport: size,
    );
    if (off == null) return null;
    final shifted = off + _camPadShift(cam);
    if (!FlatMapProjection.isOnScreen(shifted, size)) return null;
    return shifted;
  }

  // ══════════════════════════════════════════════════════════════════
  //  SECTOR LAYERS: big regions with gold boundaries. Offline, Dispatch
  //  demand controls four gold opacities; a manually disabled sector is
  //  gray. The selected active sector gets a brighter traveling border.
  //  ONE small source per sector — the single 83 KB
  //  all-cities source never materialized on iOS, while ~5 KB sources
  //  draw fine (the size class of the proven highlight source).
  //  The fields live in the state class (extensions can't declare them).
  // ══════════════════════════════════════════════════════════════════

  /// Ids of the sectors THIS driver may see — their state's set (2026-10-14
  /// user spec: a driver only sees the zones of their own state; the
  /// fail-open for a state with no sectors lives in
  /// [ZoneService.visibleSectorsFor]).
  Set<String> _zoneVisibleIds() {
    final p = _pos;
    return {
      for (final s in ZoneService.visibleSectorsFor(
          p == null ? null : ZoneService.stateOfPoint(p)))
        s.id,
    };
  }

  /// Idempotent per-fix/per-style-load sync: ensures the per-sector
  /// sources/layers exist, writes visibility + demand look (searching only
  /// — in a trip they would sit on top of the route), and refreshes the
  /// selection highlight. Every write is deduped behind signatures, so a
  /// 1 Hz call cadence costs nothing.
  Future<void> _syncZoneLayers({bool forceHighlight = false}) async {
    final map = _map;
    if (map == null || kIsWeb || !_mapStyleLoaded) return;
    if (!ZoneService.sectorsReady) return;
    // Remote kill switch (2026-10-11, black-map report): while we verify
    // the zone drawing on a real device, the layers stay off by default.
    if (!FeatureFlags.zonesMapEnabled) return;
    // First render FIRST (2026-10-12, black-map report): the writes below
    // are ~120 native style mutations that share the render thread with
    // the first tile paint — fired during style load they starved it and
    // the driver stared at a black map for ~30 s. onMapIdleListener
    // re-triggers this sync the moment the map is actually rendering.
    if (!_firstRenderDone) return;
    // A live swap paints the CURRENT demand look on its way back in — a
    // sync landing mid-animation would fight the fade.
    if (_zoneSwapRunning) return;
    final visible = _phase == _Phase.searching;
    final online = _driverOnline;
    try {
      if (!_zoneLayersReady) {
        await _createZoneLayers(map);
        _zoneLayersReady = true;
        _zoneLayersVisible = null;
        // The first time the offline zone view exists, frame the driver's
        // STATE once (2026-10-14 spec) — after that the camera is free. A
        // null fix at this instant falls back to the union view and re-runs
        // when the first real fix lands (_offlineZonesRefitPending).
        if (!_offlineZonesFitDone && !_driverOnline) {
          _offlineZonesFitDone = true;
          unawaited(_fitHomeZones(animated: false).then((landed) {
            _offlineZonesRefitPending = !landed;
          }));
        }
      }
      final demandSig = ZoneService.demand.entries
          .map((e) => '${e.key}:${e.value.level}:${e.value.off}')
          .join('|');
      // The visible-state set rides the signature: crossing a state line
      // (or the first fix landing) repaints the look for the new state.
      final visibleIds = _zoneVisibleIds();
      final visibleSig =
          '${visibleIds.join('|')}|offer:${_previewingOffer != null}';
      if (_zoneLayersVisible != visible ||
          _zoneLookOnline != online ||
          _zoneDemandSig != demandSig ||
          _zoneLookVisibleSig != visibleSig) {
        _zoneLayersVisible = visible;
        _zoneLookOnline = online;
        _zoneDemandSig = demandSig;
        _zoneLookVisibleSig = visibleSig;
        await _writeZoneVisibility(map, visible, online, visibleIds);
        _markerFrame.value++; // the pill overlay repaints with the look
      }
      final s = _sectorForHighlight;
      final id = s?.id;
      if (forceHighlight || id != _zoneHighlightName) {
        _zoneHighlightName = id;
        _markerFrame.value++;
      }
      // La selección enciende el BORDE con onda (no un fill amarillo) —
      // se evalúa en cada sync (spec 2026-10-16).
      _syncZoneWave();
    } catch (e) {
      debugPrint('[Zones] sector sync failed: $e');
    }
  }

  Future<void> _createZoneLayers(mapbox.MapboxMap map) async {
    final emptyFc =
        jsonEncode({'type': 'FeatureCollection', 'features': const []});
    // The gold goes UNDER the road network with the lines on top (2026-10-14
    // user spec: "ese dorado se colocará debajo del mapa y las líneas estarán
    // encima de ese dorado"): pin every fill below the style's lowest
    // road/tunnel layer. A style without roads falls back to the top (the
    // pre-change behaviour).
    final fillBelowId = await _zoneRoadAnchor(map);
    // Parallel batches instead of a ~120-link serial await chain
    // (2026-10-12 black-map report): every awaited platform call yields
    // the event loop, and the serial version kept the render thread busy
    // for tens of seconds. Order only matters BETWEEN batches — sources,
    // then the layers referencing them, then the data.
    await Future.wait([
      for (final s in ZoneService.sectors) _addSectorSource(map, s, emptyFc),
      _guardedStyleWrite(map.style
          .addSource(mapbox.GeoJsonSource(id: 'sec-hl-src', data: emptyFc))),
      // The spotlight mask (user spec 2026-10-12, REVIVED 2026-10-14: online
      // the driver sees their working zone and the rest dims): a world ring
      // with the chosen sector's outer rings as holes.
      _guardedStyleWrite(map.style
          .addSource(mapbox.GeoJsonSource(id: 'sec-dim-src', data: emptyFc))),
    ]);
    await Future.wait([
      for (final s in ZoneService.sectors)
        ..._addSectorLayers(map, s, fillBelowId),
    ]);
    // Stacking order matters: the dim sits ABOVE the roads (it darkens the
    // street network outside the zone) and BELOW the selection highlight in
    // stacking terms (the chosen zone keeps its gold through the hole).
    await _guardedStyleWrite(map.style.addLayer(mapbox.FillLayer(
      id: 'sec-dim',
      sourceId: 'sec-dim-src',
      fillColor: 0xFF000000,
      fillOpacity: 0.0,
    )));
    // The selection highlight: one shared source, rewritten with the
    // picked sector — brighter than any demand level ("si seleccionan
    // uno se debe poner mas amarillo"). A fill: it goes under the roads
    // with the heat gold.
    await _guardedStyleWrite(fillBelowId == null
        ? map.style.addLayer(mapbox.FillLayer(
            id: 'sec-hl-fill',
            sourceId: 'sec-hl-src',
            fillColor: 0xFFE8C547,
            fillOpacity: 0.0,
          ))
        : map.style.addLayerAt(
            mapbox.FillLayer(
              id: 'sec-hl-fill',
              sourceId: 'sec-hl-src',
              fillColor: 0xFFE8C547,
              fillOpacity: 0.0,
            ),
            mapbox.LayerPosition(below: fillBelowId)));
    // Smooth native paint transitions (2026-10-14 user spec: "se transiciona
    // de forma animada y fluida y smooth") — every repaint (heat change,
    // mode flip, selection, swap fade) interpolates instead of snapping.
    await Future.wait([
      for (final s in ZoneService.sectors) ..._sectorTransitionWrites(map, s),
      _guardedStyleWrite(map.style.setStyleLayerProperty(
          'sec-hl-fill', 'fill-opacity-transition', _kZonePaintTransition)),
      _guardedStyleWrite(map.style.setStyleLayerProperty(
          'sec-dim', 'fill-opacity-transition', _kZonePaintTransition)),
    ]);
    // Data enters AFTER the layers exist, one small write per sector — the
    // proven path. A failed write keeps the latch OPEN so the next sync
    // retries, and reports to the server (a silent catch here is what hid
    // the divisions for a week).
    final writes = await Future.wait([
      for (final f in ZoneService.sectorFeatures) _writeSectorData(map, f),
    ]);
    final failed = writes.where((ok) => !ok).length;
    if (failed > 0) {
      ApiService.logClientEvent(
          'zones_src_write_failed', 'sectors_failed=$failed');
      throw StateError('$failed sector sources rejected their data');
    }
    _zoneSectorIds = [for (final s in ZoneService.sectors) s.id];
    // The fills were just born BELOW the road network — the restack latch
    // starts there so an offline boot moves them on top exactly once.
    _zoneFillStackedOnline = true;
  }

  /// The style's lowest road/tunnel layer id — the anchor that parks the
  /// zone fills under the whole road network (labels included).
  Future<String?> _zoneRoadAnchor(mapbox.MapboxMap map) async {
    try {
      final layers = await map.style.getStyleLayers();
      for (final l in layers) {
        final id = l?.id ?? '';
        if (id.startsWith('road-') || id.startsWith('tunnel-')) return id;
      }
    } catch (e) {
      debugPrint('[Zones] style layer scan failed (fills go on top): $e');
    }
    return null;
  }

  /// The paint transition every zone layer carries (450 ms, no delay).
  static const _kZonePaintTransition = {'duration': 450, 'delay': 0};

  List<Future<void>> _sectorTransitionWrites(mapbox.MapboxMap map, Sector s) {
    final sid = s.id;
    return [
      _guardedStyleWrite(map.style.setStyleLayerProperty(
          'sec-fill-$sid', 'fill-opacity-transition', _kZonePaintTransition)),
      _guardedStyleWrite(map.style.setStyleLayerProperty(
          'sec-fill-$sid', 'fill-color-transition', _kZonePaintTransition)),
      _guardedStyleWrite(map.style.setStyleLayerProperty(
          'sec-line-$sid', 'line-opacity-transition', _kZonePaintTransition)),
      _guardedStyleWrite(map.style.setStyleLayerProperty(
          'sec-shadow-$sid', 'line-opacity-transition', _kZonePaintTransition)),
    ];
  }

  Future<void> _guardedStyleWrite(Future<void> f) async {
    try {
      await f;
    } catch (_) {}
  }

  Future<void> _addSectorSource(
      mapbox.MapboxMap map, Sector s, String emptyFc) {
    final sid = s.id;
    return _guardedStyleWrite(map.style
        .addSource(mapbox.GeoJsonSource(id: 'sec-src-$sid', data: emptyFc)));
  }

  /// Offline every sector paints one of four gold demand opacities; online
  /// only the borders remain. Active borders are gold; a sector switched
  /// off by Dispatch is gray instead.
  List<Future<void>> _addSectorLayers(mapbox.MapboxMap map, Sector s,
      [String? fillBelowId]) {
    final sid = s.id;
    final fill = mapbox.FillLayer(
      id: 'sec-fill-$sid',
      sourceId: 'sec-src-$sid',
      fillColor: 0xFFE8C547,
      fillOpacity: 0.0,
    );
    return [
      _guardedStyleWrite(fillBelowId == null
          ? map.style.addLayer(fill)
          : map.style
              .addLayerAt(fill, mapbox.LayerPosition(below: fillBelowId))),
      _guardedStyleWrite(map.style.addLayer(mapbox.LineLayer(
        id: 'sec-shadow-$sid',
        sourceId: 'sec-src-$sid',
        lineColor: 0xFFE8C547,
        lineWidth: 3.4,
        lineOpacity: 0.0,
        lineTranslate: const [0.0, 2.0],
        lineTranslateAnchor: mapbox.LineTranslateAnchor.VIEWPORT,
      ))),
      _guardedStyleWrite(map.style.addLayer(mapbox.LineLayer(
        id: 'sec-line-$sid',
        sourceId: 'sec-src-$sid',
        lineColor: 0xFFE8C547,
        lineWidth: 2.4,
        lineOpacity: 0.0,
      ))),
      _guardedStyleWrite(map.style.addLayer(mapbox.LineLayer(
        id: 'sec-glow-$sid',
        sourceId: 'sec-src-$sid',
        lineColor: 0xFFFFE066,
        lineWidth: 3.4,
        lineOpacity: 0.0,
        lineJoin: mapbox.LineJoin.ROUND,
      ))),
    ];
  }

  /// One sector's GeoJSON payload; false on failure so the caller counts
  /// it and keeps the retry latch open.
  Future<bool> _writeSectorData(
      mapbox.MapboxMap map, Map<String, dynamic> f) async {
    final sid = ((f['properties'] as Map?)?['id']) ?? '';
    if (sid.isEmpty) return true;
    try {
      await map.style.setStyleSourceProperty(
        'sec-src-$sid',
        'data',
        jsonEncode({
          'type': 'FeatureCollection',
          'features': [f],
        }),
      );
      return true;
    } catch (e) {
      debugPrint('[Zones] sector $sid data write failed: $e');
      return false;
    }
  }

  /// Fill stacking follows the mode (2026-10-14 user spec): OFFLINE the
  /// zone colors ride ON TOP of everything (only the Flutter label overlay
  /// reads above them); ONLINE they slide UNDER the road network so the
  /// streets and names read while driving. moveStyleLayer — no recreate,
  /// no paint-prop loss.
  Future<void> _restackZoneFills(mapbox.MapboxMap map, bool online) async {
    if (_zoneFillStackedOnline == online) return;
    _zoneFillStackedOnline = online;
    try {
      if (online) {
        final anchor = await _zoneRoadAnchor(map);
        if (anchor == null) return;
        await Future.wait([
          for (final s in ZoneService.sectors)
            _guardedStyleWrite(map.style.moveStyleLayer(
                'sec-fill-${s.id}', mapbox.LayerPosition(below: anchor))),
          _guardedStyleWrite(map.style.moveStyleLayer(
              'sec-hl-fill', mapbox.LayerPosition(below: anchor))),
        ]);
      } else {
        // Back on top: each fill above the roads again, tucked under its own
        // boundary line — the creation order of old.
        final lastId =
            ZoneService.sectors.isEmpty ? null : ZoneService.sectors.last.id;
        await Future.wait([
          for (final s in ZoneService.sectors)
            _guardedStyleWrite(map.style.moveStyleLayer('sec-fill-${s.id}',
                mapbox.LayerPosition(below: 'sec-shadow-${s.id}'))),
          if (lastId != null)
            _guardedStyleWrite(map.style.moveStyleLayer('sec-hl-fill',
                mapbox.LayerPosition(above: 'sec-line-$lastId'))),
        ]);
      }
    } catch (e) {
      debugPrint('[Zones] fill restack failed: $e');
    }
  }

  /// Offline fills go from the faintest gold (Sin viajes) to the strongest
  /// semi-transparent gold (Muy ocupado). Online only borders remain: gold
  /// for active sectors, gray for a sector switched off by Dispatch.
  Future<void> _writeZoneVisibility(mapbox.MapboxMap map, bool visible,
      bool online, Set<String> visibleIds) async {
    // The fill stacking follows the mode (offline on top / online under the
    // roads) — restack BEFORE repainting so a flip never flashes wrong.
    await _restackZoneFills(map, online);
    // One parallel batch — the serial per-property awaits were part of the
    // render-thread pile-up (2026-10-12 black-map report). A sector outside
    // the driver's state keeps its layers but paints at opacity 0
    // (2026-10-14 spec: state-separated visibility without layer churn).
    await Future.wait([
      for (final s in ZoneService.sectors)
        _writeSectorLook(map, s, visible && visibleIds.contains(s.id), online),
    ]);
    // The selection highlight fill MURIÓ (user spec 2026-10-16: "no se
    // prendera en amarillo si no el borde se iluminara") — la selección es
    // ahora el BORDE con la onda viajera (_syncZoneWave). La capa
    // sec-hl-fill se queda creada pero jamás pinta.
    final sel = _selectedZoneName;
    // The spotlight (user spec 2026-10-12, REVIVED 2026-10-14 "sí"): online
    // + a chosen zone → everything OUTSIDE the zone dims to barely-visible.
    // No selection → no mask.
    final spotlight =
        visible && online && sel != null && _previewingOffer == null;
    await _writeZoneDim(map, spotlight ? ZoneService.sectorById(sel) : null);
    try {
      await map.style.setStyleLayerProperty('sec-hl-fill', 'fill-opacity', 0.0);
    } catch (_) {}
  }

  /// The spotlight mask: a world-sized polygon with the chosen sector's
  /// outer rings as holes. `null` = mask off (every sector visible).
  Future<void> _writeZoneDim(mapbox.MapboxMap map, Sector? sec) async {
    final effectiveSec = _previewingOffer == null ? sec : null;
    var fc = <String, dynamic>{
      'type': 'FeatureCollection',
      'features': const [],
    };
    if (effectiveSec != null) {
      // Ring 0 of each poly is the sector's outer boundary — each becomes a
      // hole in the world ring (the sector's own holes stay dimmed: they
      // are not part of the zone either).
      final holes = [
        for (final poly in effectiveSec.polys)
          [
            for (final p in poly.first) [p.longitude, p.latitude]
          ]
      ];
      if (holes.isNotEmpty) {
        fc = {
          'type': 'FeatureCollection',
          'features': [
            {
              'type': 'Feature',
              'properties': const {},
              'geometry': {
                'type': 'Polygon',
                'coordinates': [
                  const [
                    [-179.9, -85.0],
                    [179.9, -85.0],
                    [179.9, 85.0],
                    [-179.9, 85.0],
                    [-179.9, -85.0]
                  ],
                  ...holes,
                ],
              },
            }
          ],
        };
      }
    }
    try {
      await map.style
          .setStyleSourceProperty('sec-dim-src', 'data', jsonEncode(fc));
      await map.style.setStyleLayerProperty(
          'sec-dim', 'fill-opacity', effectiveSec == null ? 0.0 : 0.25);
    } catch (e) {
      debugPrint('[Zones] dim write failed: $e');
    }
  }

  Future<void> _writeSectorLook(
      mapbox.MapboxMap map, Sector s, bool visible, bool online) async {
    final sid = s.id;
    final demand = visible ? ZoneService.demand[sid] : null;
    final off = demand?.off ?? false;
    final level = off ? 0 : demand?.level ?? 0;
    const gold = 0xFFE8C547;
    const gray = 0xFF7F858E;
    final color = off ? gray : gold;
    // Offline: Sin viajes 8%, Lento 18%, Ocupado 32%, Muy ocupado 48%.
    // Online solo quedan los bordes. El apagado manual siempre gana: gris.
    final fillOpacity = !visible || online
        ? 0.0
        : off
            ? 0.20
            : level == 0
                ? 0.08
                : level == 1
                    ? 0.18
                    : level == 2
                        ? 0.32
                        : 0.48;
    try {
      await Future.wait([
        map.style.setStyleLayerProperty('sec-fill-$sid', 'fill-color', color),
        map.style.setStyleLayerProperty(
            'sec-fill-$sid', 'fill-opacity', fillOpacity),
        map.style.setStyleLayerProperty('sec-line-$sid', 'line-color', color),
        map.style.setStyleLayerProperty(
            'sec-line-$sid', 'line-opacity', visible ? 0.85 : 0.0),
        map.style.setStyleLayerProperty('sec-shadow-$sid', 'line-opacity', 0.0),
        map.style.setStyleLayerProperty('sec-glow-$sid', 'line-opacity', 0.0),
      ]);
    } catch (_) {}
  }

  // Selected sector: a bright gold pulse on its own layer, never a gradient.
  // This keeps polygon borders gold on native Mapbox builds where the old
  // line-gradient path could render the selected sector black.
  void _syncZoneWave() {
    final sel = _selectedZoneName;
    final active = _map != null &&
        !kIsWeb &&
        _mapMounted &&
        _zoneLayersReady &&
        _phase == _Phase.searching &&
        sel != null;
    if (!active) {
      _stopZoneWave();
      return;
    }
    if (_zoneWaveSectorId != sel) {
      _stopZoneWave();
      _zoneWaveSectorId = sel;
      _zoneWavePhase = 0;
      _paintZoneWaveBase(sel);
    }
    _zoneWaveTimer ??= Timer.periodic(const Duration(milliseconds: 200), (_) {
      _tickZoneWave();
    });
  }

  double get _zoneGlowOpacity =>
      0.60 + 0.40 * (0.5 + 0.5 * math.sin(_zoneWavePhase * 2 * math.pi));

  Future<void> _paintZoneWaveBase(String sid) async {
    final map = _map;
    if (map == null || kIsWeb) return;
    try {
      await Future.wait([
        map.style
            .setStyleLayerProperty('sec-line-$sid', 'line-color', 0xFFE8C547),
        map.style.setStyleLayerProperty('sec-line-$sid', 'line-width', 3.0),
        map.style
            .setStyleLayerProperty('sec-glow-$sid', 'line-color', 0xFFFFE066),
        map.style.setStyleLayerProperty('sec-glow-$sid', 'line-width', 3.4),
        map.style.setStyleLayerProperty('sec-glow-$sid', 'line-opacity', 0.90),
      ]);
    } catch (e) {
      debugPrint('[Zones] selection paint failed: $e');
    }
  }

  void _tickZoneWave() {
    final map = _map;
    final sid = _zoneWaveSectorId;
    if (map == null || sid == null || !mounted || !_mapMounted) {
      _zoneWaveTimer?.cancel();
      _zoneWaveTimer = null;
      return;
    }
    if (!_appInForeground) return;
    _zoneWavePhase = (_zoneWavePhase + 0.04) % 1.0;
    if (_zoneWaveWriteBusy) {
      _zoneWavePendingPhase = _zoneWavePhase;
      return;
    }
    _zoneWaveWriteBusy = true;
    map.style
        .setStyleLayerProperty(
            'sec-glow-$sid', 'line-opacity', _zoneGlowOpacity)
        .then((_) {
      _zoneWaveWriteBusy = false;
      if (!mounted || !identical(map, _map)) return;
      final pending = _zoneWavePendingPhase;
      if (pending != null) {
        _zoneWavePendingPhase = null;
        _zoneWavePhase = pending;
        _tickZoneWave();
      }
    }).catchError((Object e) {
      _zoneWaveWriteBusy = false;
      debugPrint('[Zones] selection pulse failed: $e');
    });
  }

  void _stopZoneWave() {
    _zoneWaveTimer?.cancel();
    _zoneWaveTimer = null;
    _zoneWaveWriteBusy = false;
    _zoneWavePendingPhase = null;
    final map = _map;
    final prev = _zoneWaveSectorId;
    _zoneWaveSectorId = null;
    if (map == null || kIsWeb || prev == null) return;
    final off = ZoneService.demand[prev]?.off ?? false;
    final color = off ? 0xFF7F858E : 0xFFE8C547;
    _guardedStyleWrite(
        map.style.setStyleLayerProperty('sec-glow-$prev', 'line-opacity', 0.0));
    _guardedStyleWrite(
        map.style.setStyleLayerProperty('sec-line-$prev', 'line-color', color));
    _guardedStyleWrite(
        map.style.setStyleLayerProperty('sec-line-$prev', 'line-width', 2.4));
  }

  /// Live boundary refresh (2026-10-13, user spec: "instantáneo, que se
  /// dibuje de forma animada trasladándose en el mapa, sin cerrar la app").
  /// ZoneService swapped the sector set — fade everything out, reconcile
  /// sources/layers with the new ids, then stagger the fade back in.
  void _onSectorsChanged() {
    if (!_mapStyleLoaded || !_firstRenderDone) return;
    if (!FeatureFlags.zonesMapEnabled) return;
    if (!_zoneLayersReady) {
      // Layers never existed — the normal sync creates them (no animation).
      _syncZoneLayers(forceHighlight: true);
      return;
    }
    unawaited(_animateZoneSwap());
  }

  Future<void> _animateZoneSwap() async {
    final map = _map;
    if (map == null || kIsWeb || _zoneSwapRunning) return;
    _zoneSwapRunning = true;
    try {
      // a. Fade-out: every sector layer + the highlight to 0 in one batch.
      await Future.wait([
        for (final id in _zoneSectorIds) ...[
          _guardedStyleWrite(map.style
              .setStyleLayerProperty('sec-fill-$id', 'fill-opacity', 0.0)),
          _guardedStyleWrite(map.style
              .setStyleLayerProperty('sec-line-$id', 'line-opacity', 0.0)),
          _guardedStyleWrite(map.style
              .setStyleLayerProperty('sec-shadow-$id', 'line-opacity', 0.0)),
          _guardedStyleWrite(map.style
              .setStyleLayerProperty('sec-glow-$id', 'line-opacity', 0.0)),
        ],
        _guardedStyleWrite(map.style
            .setStyleLayerProperty('sec-hl-fill', 'fill-opacity', 0.0)),
        _guardedStyleWrite(
            map.style.setStyleLayerProperty('sec-dim', 'fill-opacity', 0.0)),
      ]);
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;

      // b. Reconcile sources/layers with the new sector ids: remove the
      // ones that no longer exist, create the newcomers (born EMPTY, data
      // enters by setStyleSourceProperty like the bootstrap), then rewrite
      // every sector's geometry — it may have moved with the id intact.
      final newIds = [for (final s in ZoneService.sectors) s.id];
      var reconcileFailed = false;
      for (final id in _zoneSectorIds.where((id) => !newIds.contains(id))) {
        try {
          await map.style.removeStyleLayer('sec-fill-$id');
        } catch (_) {}
        try {
          await map.style.removeStyleLayer('sec-line-$id');
        } catch (_) {}
        try {
          await map.style.removeStyleLayer('sec-shadow-$id');
        } catch (_) {}
        try {
          await map.style.removeStyleLayer('sec-glow-$id');
        } catch (_) {}
        try {
          await map.style.removeStyleSource('sec-src-$id');
        } catch (e) {
          reconcileFailed = true;
          debugPrint('[Zones] stale sector $id removal failed: $e');
        }
      }
      final added = [
        for (final s in ZoneService.sectors)
          if (!_zoneSectorIds.contains(s.id)) s
      ];
      if (added.isNotEmpty) {
        final emptyFc =
            jsonEncode({'type': 'FeatureCollection', 'features': const []});
        await Future.wait([
          for (final s in added) _addSectorSource(map, s, emptyFc),
        ]);
        final fillBelowId = await _zoneRoadAnchor(map);
        await Future.wait([
          for (final s in added) ..._addSectorLayers(map, s, fillBelowId),
        ]);
        await Future.wait([
          for (final s in added) ..._sectorTransitionWrites(map, s),
        ]);
        // Newcomers are born below the roads (the creation rule) — if the
        // stack is currently offline (fills on top), move JUST these up to
        // match.
        if (_zoneFillStackedOnline == false) {
          await Future.wait([
            for (final s in added)
              _guardedStyleWrite(map.style.moveStyleLayer('sec-fill-${s.id}',
                  mapbox.LayerPosition(below: 'sec-shadow-${s.id}'))),
          ]);
        }
      }
      _zoneSectorIds = newIds;
      final writes = await Future.wait([
        for (final f in ZoneService.sectorFeatures) _writeSectorData(map, f),
      ]);
      final failed = writes.where((ok) => !ok).length;
      if (reconcileFailed || failed > 0) {
        ApiService.logClientEvent('zones_swap',
            'reconcile_failed=$reconcileFailed sectors_failed=$failed');
      }
      if (!mounted) return;

      // c. Staggered fade-in (~50 ms steps, alphabetical order) back to the
      // look of the moment — same levels as _writeSectorLook, same
      // state-visibility filter as _writeZoneVisibility.
      final visible = _phase == _Phase.searching;
      final online = _driverOnline;
      final visibleIds = _zoneVisibleIds();
      final ordered = [...ZoneService.sectors]
        ..sort((a, b) => a.id.compareTo(b.id));
      for (final s in ordered) {
        if (!mounted) return;
        unawaited(_writeSectorLook(
            map, s, visible && visibleIds.contains(s.id), online));
        await Future.delayed(const Duration(milliseconds: 50));
      }
      // The spotlight mask rewrites too — the sector geometry it holes out
      // may have moved, and the online/selection state is of this moment.
      final sel = _selectedZoneName;
      final spotlight =
          visible && online && sel != null && _previewingOffer == null;
      await _writeZoneDim(map, spotlight ? ZoneService.sectorById(sel) : null);
      try {
        // El fill de selección no pinta NUNCA (2026-10-16) — la selección
        // es el borde con onda viajera.
        await map.style
            .setStyleLayerProperty('sec-hl-fill', 'fill-opacity', 0.0);
      } catch (_) {}
      _zoneLayersVisible = visible;
      _zoneLookOnline = online;
      _zoneLookVisibleSig =
          '${visibleIds.join('|')}|offer:${_previewingOffer != null}';
      _zoneDemandSig = ZoneService.demand.entries
          .map((e) => '${e.key}:${e.value.level}')
          .join('|');
      final hl = _sectorForHighlight;
      _zoneHighlightName = hl?.id;
      _syncZoneWave();
      _markerFrame.value++; // the label/pill overlay re-reads the sectors
    } catch (e) {
      debugPrint('[Zones] animated swap failed: $e');
      ApiService.logClientEvent('zones_swap', 'error=$e');
    } finally {
      _zoneSwapRunning = false;
      unawaited(_syncZoneLayers());
    }
  }

  /// The union fit — every sector of every state. Only a fallback now: the
  /// offline resting view is [_fitHomeZones] (the driver's STATE,
  /// 2026-10-14); this frames everything when no fix exists to group by.
  Future<void> _fitAllZones({bool animated = true}) =>
      _fitSectors(ZoneService.sectors, animated: animated);

  /// The home fit (2026-10-14, user spec: "yo estoy en alabama y la app me
  /// abre mostrando las zonas de florida — debe abrir donde está el
  /// driver"): the zones of the driver's STATE (Florida or Alabama, from
  /// the embedded outlines), never the two-state union. No position or a
  /// point outside both states → the union fallback.
  ///
  /// Returns false when it fell back for lack of a position — the caller
  /// (boot) re-runs it once the first real fix lands, so a cold GPS never
  /// strands the resting view on the wrong state.
  Future<bool> _fitHomeZones({bool animated = true, LatLng? at}) async {
    final pos = at ?? _pos;
    if (pos == null) {
      await _fitAllZones(animated: animated);
      return false;
    }
    await _fitSectors(
        ZoneService.sectorsForState(ZoneService.stateOfPoint(pos)),
        animated: animated);
    return true;
  }

  /// Offline recentre frames every sector in the driver's state, north-up,
  /// without re-engaging arrow follow. With no position it falls back to the
  /// union of all sectors. The visible sheet inset belongs to the fit.
  /// El sheet abierto cubre la mitad baja de la pantalla (user spec
  /// 2026-10-15: "debe centrar en lo visible") — las cámaras offline centran
  /// en el área VISIBLE sobre el sheet, no en el centro de la pantalla.
  double get _visibleSheetPx {
    final h = MediaQuery.maybeOf(context)?.size.height ?? 700.0;
    return h * _panelFrac + 20;
  }

  Future<void> _recenterArrowZoneZoom() async {
    try {
      await _fitHomeZones();
    } catch (e) {
      debugPrint('[Zones] home-state fit failed: $e');
      ApiService.logClientEvent(
          'recenter_fit', 'scope=arrow_zone_zoom_fallback');
      await _fitAllZones();
    }
  }

  /// Union bbox [w, s, e, n] of a sector list, or null when empty.
  List<double>? _sectorsBBox(List<Sector> sectors) {
    if (sectors.isEmpty) return null;
    var w = 999.0, s = 999.0, e = -999.0, n = -999.0;
    for (final sec in sectors) {
      w = math.min(w, sec.bbox[0]);
      s = math.min(s, sec.bbox[1]);
      e = math.max(e, sec.bbox[2]);
      n = math.max(n, sec.bbox[3]);
    }
    return w > e || s > n ? null : [w, s, e, n];
  }

  void _pauseFollowForZoneFit() {
    _recenterLanding = null;
    _pendingCamWrite = null;
    if (_cameraFollowing) _setState(() => _cameraFollowing = false);
  }

  Future<void> _fitSectors(List<Sector> sectors, {bool animated = true}) async {
    final map = _map;
    if (map == null || kIsWeb || !ZoneService.sectorsReady) return;
    _pauseFollowForZoneFit();
    final bbox = _sectorsBBox(sectors);
    if (bbox == null) return;
    final w = bbox[0], s = bbox[1], e = bbox[2], n = bbox[3];
    // Token anti-stale (user report 2026-10-16-noche: "cuando me pongo
    // online y me desconecto el boton de centrar no funciona despues"): el
    // fit del flip quedaba en vuelo cuando el driver tocaba recentrar y
    // aterrizaba DESPUÉS, pisando el recenter — un fit viejo muere si otro
    // fit/recenter arrancó después.
    final seq = _cameraActionGate.begin();
    try {
      final cam = await map.cameraForCoordinatesPadding(
        [
          mapbox.Point(coordinates: mapbox.Position(w, s)),
          mapbox.Point(coordinates: mapbox.Position(e, n)),
        ],
        mapbox.CameraOptions(pitch: 0, bearing: 0),
        // Top clears the earnings pill; bottom = el área visible real
        // sobre el sheet abierto (2026-10-15 spec "centrar en lo visible").
        mapbox.MbxEdgeInsets(
            top: 130, left: 30, bottom: _visibleSheetPx, right: 30),
        null,
        null,
      );
      if (!_cameraActionGate.isCurrent(seq))
        return; // un recenter/fit más nuevo manda
      // Programmatic — wear the suppression so the flight's own camera
      // events never read as a manual rotate/gesture.
      _camFlightUntil = DateTime.now()
          .add(const Duration(milliseconds: _kRecenterFlightMs + 320));
      await map.flyTo(
          cam,
          mapbox.MapAnimationOptions(
              duration: animated ? _kRecenterFlightMs : 0));
      if (mounted && _cameraActionGate.isCurrent(seq)) {
        _setState(() => _cameraFollowing = false);
      }
    } catch (e) {
      debugPrint('[Zones] fit-all failed: $e');
    }
  }

  /// Frame ONE sector NORTH-UP (user spec 2026-10-13: "ver la zona completa
  /// de forma recta, no de lado") — the zone compass view is always bearing
  /// 0, never rotated to the driver's heading. A free view: follow stays off
  /// until the driver starts rolling.
  Future<void> _fitZone(Sector sec) async {
    final map = _map;
    if (map == null || kIsWeb) return;
    _pauseFollowForZoneFit();
    final b = sec.bbox;
    // Mismo token anti-stale que los otros fits (2026-10-16-noche): un fit
    // de zona viejo jamás aterriza sobre una cámara más nueva.
    final seq = _cameraActionGate.begin();
    try {
      final cam = await map.cameraForCoordinatesPadding(
        [
          mapbox.Point(coordinates: mapbox.Position(b[0], b[1])),
          mapbox.Point(coordinates: mapbox.Position(b[2], b[3])),
        ],
        mapbox.CameraOptions(pitch: 0, bearing: 0),
        mapbox.MbxEdgeInsets(top: 130, left: 50, bottom: 210, right: 50),
        null,
        null,
      );
      if (!_cameraActionGate.isCurrent(seq)) return;
      _camFlightUntil = DateTime.now()
          .add(const Duration(milliseconds: _kRecenterFlightMs + 320));
      await map.flyTo(
          cam, mapbox.MapAnimationOptions(duration: _kRecenterFlightMs));
      if (mounted && _cameraActionGate.isCurrent(seq)) {
        _setState(() => _cameraFollowing = false);
      }
    } catch (e) {
      debugPrint('[Zones] fit-zone failed: $e');
    }
  }

  /// The LEFT online FAB (user spec 2026-10-13: "el botón de recentrar de la
  /// izquierda será una brújula para ver la zona completa de forma recta… y
  /// el de la derecha para centrar la flecha"): frames the whole working
  /// zone north-up. The right FAB keeps centering the arrow.
  void _onZoneCompassTap() {
    final sel = _selectedZoneName;
    final sec = sel != null ? ZoneService.sectorById(sel) : null;
    if (sec == null) return;
    HapticService.selectionClick();
    ApiService.logClientEvent('recenter_fit', 'scope=zone:${sec.id}');
    unawaited(_fitZone(sec));
  }

  /// Sector selection by tap (user spec 2026-10-11/12: tap a sector and the
  /// GO button lights up animated; no selection = GO stays dim. A tap
  /// outside every sector keeps the current selection, a re-tap on the same
  /// sector deselects — toggle). Offline + searching only.
  void _onZoneMapTap(dynamic ctx) {
    if (!FeatureFlags.zonesMapEnabled) return;
    if (_phase != _Phase.searching || _driverOnline) return;
    final coords = ctx.point.coordinates;
    final s = ZoneService.sectorContaining(
        LatLng(coords.lat.toDouble(), coords.lng.toDouble()));
    if (s == null) return;
    // State separation (2026-10-14 user spec): a driver selects only a zone
    // of THEIR state — the other state's sectors are invisible anyway, so a
    // tap on one (e.g. at a border) must not arm the GO. Fail-open when the
    // driver's state has no sectors of its own (visibleSectorsFor).
    final p = _pos;
    if (!ZoneService.visibleSectorsFor(
            p == null ? null : ZoneService.stateOfPoint(p))
        .any((v) => v.id == s.id)) {
      return;
    }
    if (_selectedZoneName == s.id) {
      _setState(() => _selectedZoneName = null);
      PrefsCache.instance.then((p) => p.remove('driver_selected_zone'));
      _syncZoneLayers(forceHighlight: true);
      return;
    }
    _setState(() => _selectedZoneName = s.id);
    // The working zone survives app restarts (user spec 2026-10-13: "la zona
    // debe mantenerse cuando se cierra y se abre la app").
    PrefsCache.instance.then((p) => p.setString('driver_selected_zone', s.id));
    HapticService.selectionClick();
    if (ZoneService.demand[s.id]?.off != true) {
      _goIgniteCtrl?.forward(from: 0.0);
    }
    _syncZoneLayers(forceHighlight: true);
  }

  /// The sector the highlight follows: the driver's SELECTION wins; with no
  /// selection, their physical sector (the photo behaviour).
  Sector? get _sectorForHighlight {
    final sel = _selectedZoneName;
    if (sel != null) return ZoneService.sectorById(sel);
    final p = _pos;
    return p == null ? null : ZoneService.sectorContaining(p);
  }

  /// Sector labels + demand pills — Flutter overlays glued per frame from
  /// the same flat projection the arrow uses (NEVER a native text layer:
  /// the 2026-10-11 black-map incident). Offline + searching only; online
  /// keeps just the boundary lines, per spec.
  Widget _zoneLabelOverlay() {
    if (kIsWeb) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: _markerFrame,
      builder: (_, __) {
        if (!FeatureFlags.zonesMapEnabled) return const SizedBox.shrink();
        if (_driverOnline) return const SizedBox.shrink();
        if (_phase != _Phase.searching) return const SizedBox.shrink();
        // Nunca sobre el velo/negro de un remount (user report 2026-10-16-
        // noche: al volver de Schedule el mapa tarda y las etiquetas
        // flotaban sobre el vacío) — solo con el mapa real renderizando.
        if (!_mapStyleLoaded || !_firstRenderDone) {
          return const SizedBox.shrink();
        }
        final cam = _onlineCamState;
        final size = _onlineMapSize;
        if (cam == null || size == null) return const SizedBox.shrink();
        final c = cam.center.coordinates;
        final camCenter = LatLng(c.lat.toDouble(), c.lng.toDouble());
        Offset? project(LatLng t) {
          final off = FlatMapProjection.screenOffsetHeading(
            target: t,
            cameraCenter: camCenter,
            zoom: cam.zoom,
            bearingDeg: cam.bearing,
            pitchDeg: cam.pitch,
            viewport: size,
          );
          if (off == null) return null;
          final shifted = off + _camPadShift(cam);
          if (!FlatMapProjection.isOnScreen(shifted, size)) {
            return null;
          }
          return shifted;
        }

        final children = <Widget>[];
        // The highlighted sector's name (selection wins, else physical).
        final hl = _sectorForHighlight;
        if (hl != null) {
          final off = project(hl.center);
          if (off != null) {
            children.add(Positioned(
              left: off.dx,
              top: off.dy,
              child: IgnorePointer(
                child: FractionalTranslation(
                  translation: const Offset(-0.5, -0.5),
                  child: Text(
                    hl.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      shadows: [
                        Shadow(color: Colors.black, blurRadius: 3),
                        Shadow(color: Colors.black, offset: Offset(0, 1)),
                      ],
                    ),
                  ),
                ),
              ),
            ));
          }
        }
        // Demand pills on the hot sectors (level ≥ 2 gets the pill; level 1
        // is just the gold fill). Only the driver's OWN state (2026-10-14
        // spec: the other state's zones are neither drawn nor labelled).
        final p = _pos;
        for (final s in ZoneService.visibleSectorsFor(
            p == null ? null : ZoneService.stateOfPoint(p))) {
          final d = ZoneService.demand[s.id];
          if (d == null || d.level < 2) continue;
          if (hl != null && s.id == hl.id) {
            // The pill rides slightly above the name label.
          }
          final off = project(s.center);
          if (off == null) continue;
          final isMax = d.level >= 3;
          final label =
              isMax ? S.of(context).zoneVeryBusy : S.of(context).zoneBusy;
          final bonus =
              d.bonus > 0 ? '  ·  +\$${d.bonus.toStringAsFixed(2)}' : '';
          children.add(Positioned(
            left: off.dx,
            top: off.dy + (hl != null && s.id == hl.id ? -26 : 0),
            child: IgnorePointer(
              child: FractionalTranslation(
                translation: const Offset(-0.5, -0.5),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: isMax
                        ? const Color(0xFFE8C547)
                        : const Color(0xFF14141A),
                    borderRadius: BorderRadius.circular(20),
                    border:
                        Border.all(color: const Color(0xFFE8C547), width: 1.2),
                    boxShadow: const [
                      BoxShadow(color: Colors.black54, blurRadius: 6),
                    ],
                  ),
                  child: Text(
                    '$label$bonus',
                    style: TextStyle(
                      color: isMax ? Colors.black : const Color(0xFFE8C547),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ));
        }
        if (children.isEmpty) return const SizedBox.shrink();
        return Stack(children: children);
      },
    );
  }

  /// Gold airport pills for the driver's working state (2026-10-22, owner
  /// spec: "solo los grandes", VISUAL ONLY — IgnorePointer, no tap): same
  /// flat-projection zero-IPC pipeline as the zone pills, in BOTH searching
  /// views (offline zone map and online "Finding trips"). Hidden beyond
  /// zoom 8.5 (map clutter) and during navigation phases.
  Widget _airportPillOverlay() {
    if (kIsWeb) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: _markerFrame,
      builder: (_, __) {
        if (_phase != _Phase.searching) return const SizedBox.shrink();
        // Misma regla que las etiquetas de zona: nunca sobre el velo/negro
        // de un remount.
        if (!_mapStyleLoaded || !_firstRenderDone) {
          return const SizedBox.shrink();
        }
        final cam = _onlineCamState;
        final size = _onlineMapSize;
        if (cam == null || size == null) return const SizedBox.shrink();
        if (cam.zoom < 8.5) return const SizedBox.shrink();
        final p = _pos;
        final airports = airportsForState(_driveStateCode ??
            (p == null ? null : ZoneService.stateOfPoint(p)));
        if (airports.isEmpty) return const SizedBox.shrink();
        final c = cam.center.coordinates;
        final camCenter = LatLng(c.lat.toDouble(), c.lng.toDouble());
        final children = <Widget>[];
        for (final a in airports) {
          final off = FlatMapProjection.screenOffsetHeading(
            target: LatLng(a.lat, a.lng),
            cameraCenter: camCenter,
            zoom: cam.zoom,
            bearingDeg: cam.bearing,
            pitchDeg: cam.pitch,
            viewport: size,
          );
          if (off == null) continue;
          final shifted = off + _camPadShift(cam);
          if (!FlatMapProjection.isOnScreen(shifted, size)) continue;
          children.add(Positioned(
            left: shifted.dx,
            top: shifted.dy,
            child: IgnorePointer(
              child: FractionalTranslation(
                translation: const Offset(-0.5, -0.5),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF14141A),
                    borderRadius: BorderRadius.circular(20),
                    border:
                        Border.all(color: const Color(0xFFE8C547), width: 1.2),
                    boxShadow: const [
                      BoxShadow(color: Colors.black54, blurRadius: 6),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.flight_rounded,
                          color: Color(0xFFE8C547), size: 14),
                      const SizedBox(width: 4),
                      Text(
                        a.code,
                        style: const TextStyle(
                          color: Color(0xFFE8C547),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ));
        }
        if (children.isEmpty) return const SizedBox.shrink();
        return Stack(children: children);
      },
    );
  }
}
