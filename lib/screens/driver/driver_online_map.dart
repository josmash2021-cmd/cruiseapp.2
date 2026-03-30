part of 'driver_online_screen.dart';

// ══════════════════════════════════════════════════════════════
//  MAP — annotations, route preview, camera, pin builders
// ══════════════════════════════════════════════════════════════

extension _DriverOnlineMap on _DriverOnlineScreenState {

  /// Update the driver car / golden dot annotation on the Mapbox map.
  Future<void> _updateDriverAnnotation() async {
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

  // ═══════════════════════════════════════════════════════════
  //  MAPBOX ANNOTATION HELPERS
  // ═══════════════════════════════════════════════════════════

  Future<void> _setRouteAnnotation(List<LatLng> pts, Color c) async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null || pts.length < 2) return;
    if (_routeAnnot != null) {
      try { await polyMgr.delete(_routeAnnot!); } catch (_) {}
      _routeAnnot = null;
    }
    final coords = pts.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    _routeAnnot = await polyMgr.create(mapbox.PolylineAnnotationOptions(
      geometry: mapbox.LineString(coordinates: coords),
      lineColor: c.toARGB32(),
      lineWidth: 5.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));
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
    final pointMgr = _pointAnnotMgr;
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
    final pointMgr = _pointAnnotMgr;
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
    final pointMgr = _pointAnnotMgr;
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
    final pointMgr = _pointAnnotMgr;
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
    // Use generous bottom padding so route + pins sit well above the offer card
    final screenH = MediaQuery.of(context).size.height;
    final cardArea = (_pendingOffers.isNotEmpty || _previewingOffer != null)
        ? (screenH * 0.45).clamp(220, 380).toDouble()
        : 60.0;
    _map!.cameraForCoordinatesPadding(
      coords,
      mapbox.CameraOptions(pitch: 20),
      mapbox.MbxEdgeInsets(top: 100, left: 60, bottom: cardArea + 40, right: 60),
      null, null,
    ).then((cam) {
      if (mounted) _map?.flyTo(cam, mapbox.MapAnimationOptions(duration: 700));
    });
  }

  /// Auto-trigger cinematic route preview when first offer arrives.
  /// Uses the same logic as card tap but runs automatically.
  void _autoTriggerRoutePreview(Map<String, dynamic> offer) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingOffers.isEmpty) return;
      _onOfferCardTap(offer);
    });
  }

  // ── Cinematic offer card tap → full animation sequence ──
  // Everything is pre-loaded: route, pins, place type, bounds.
  // Zero network calls on tap.
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
    await _clearAllAnnotations();

    // Load from cache (pre-fetched on offer arrival)
    final cached = _routeCache[oid];
    if (cached != null) {
      _fullSegOne = cached.segOne;
      _fullSegTwo = cached.segTwo;
    } else {
      // Fallback: fetch now (should be rare)
      final routeFutures = await Future.wait([
        _fetchRoutePoints(_pos!, pickupLL),
        _fetchRoutePoints(pickupLL, dropoffLL),
      ]);
      _fullSegOne = routeFutures[0];
      _fullSegTwo = routeFutures[1];
    }
    if (!mounted || _previewingOffer == null) { _isCardAnimating = false; return; }

    // ── PHASE 1: Smooth zoom out to show full route (instant) ──
    _fitBoundsMulti([_pos!, pickupLL, dropoffLL]);

    // ── PHASE 3: Pins pop in (after one frame for camera to settle) ──
    await Future.delayed(const Duration(milliseconds: 50));
    if (!mounted || _previewingOffer == null) { _isCardAnimating = false; return; }

    // Place pins using pre-built images (or build now as fallback)
    final dropoffAddr = (offer['dropoff_address'] ?? '') as String;
    final placeType = cached?.dropoffPlaceType ?? _detectPlaceType(dropoffAddr);
    Uint8List? pickupPinImg = cached?.pickupPin;
    Uint8List? dropoffPinImg = cached?.dropoffPin;
    if (pickupPinImg == null || dropoffPinImg == null) {
      final pinResults = await Future.wait([
        renderCircularPinBytes(icon: CircularPinIcon.person, isPickup: true, radius: 32),  // pickup
        renderCircularPinBytes(icon: _goldPinIconFor(placeType), isPickup: false, radius: 32), // dropoff
      ]);
      pickupPinImg ??= pinResults[0];
      dropoffPinImg ??= pinResults[1];
    }

    final pointMgr = _pointAnnotMgr;
    if (pointMgr != null && mounted) {
      // Pickup pin — person icon (CENTER anchor = pin sits exactly at coordinate)
      _prevPickupAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(pickupLL.longitude, pickupLL.latitude)),
        image: pickupPinImg, iconSize: 0.01, iconAnchor: mapbox.IconAnchor.CENTER,
      ));
      // Dropoff pin — smart icon (house/store/airplane)
      _prevDropoffAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(dropoffLL.longitude, dropoffLL.latitude)),
        image: dropoffPinImg, iconSize: 0.01, iconAnchor: mapbox.IconAnchor.CENTER,
      ));

      // Animate pin pop: scale 0.01 → 1.2 → 0.9 → 1.0 over 600ms
      await _animatePinPop();
    }

    // ── PHASE 4 (t=700ms): Gold gloss route draws ──
    if (!mounted || _previewingOffer == null) { _isCardAnimating = false; return; }
    final fullRoute = [..._fullSegOne, ..._fullSegTwo];
    await _drawGoldGlossRoute(fullRoute);
    if (!mounted || _previewingOffer == null) { _isCardAnimating = false; return; }

    // ── PHASE 5: Route shown ──

    if (mounted && _previewingOffer != null) {
      _setState(() => _offerRouteShown = true);
    }

    // Re-fit camera for final framing (next frame)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _previewingOffer != null) {
        _fitBoundsMulti([_pos!, pickupLL, dropoffLL]);
      }
    });
    _isCardAnimating = false;
  }

  /// Animate all preview pins from tiny → overshoot → settle (spring feel)
  Future<void> _animatePinPop() async {
    final pointMgr = _pointAnnotMgr;
    if (pointMgr == null) return;
    const totalMs = 600;
    final stopwatch = Stopwatch()..start();
    final completer = Completer<void>();

    // Spring-like TweenSequence: 0→1.2→0.9→1.0
    double springScale(double t) {
      if (t < 0.6) {
        // 0→1.2 with easeOutCubic
        final p = (t / 0.6).clamp(0.0, 1.0);
        return Curves.easeOutCubic.transform(p) * 1.2;
      } else if (t < 0.8) {
        // 1.2→0.9
        final p = ((t - 0.6) / 0.2).clamp(0.0, 1.0);
        return 1.2 - 0.3 * Curves.easeInOut.transform(p);
      } else {
        // 0.9→1.0
        final p = ((t - 0.8) / 0.2).clamp(0.0, 1.0);
        return 0.9 + 0.1 * Curves.elasticOut.transform(p);
      }
    }

    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = createTicker((_) async {
      if (!mounted) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      final elapsed = stopwatch.elapsedMilliseconds;
      final progress = (elapsed / totalMs).clamp(0.0, 1.0);
      final scale = springScale(progress);

      for (final annot in [_prevPickupAnnot, _prevDropoffAnnot]) {
        if (annot != null) {
          annot.iconSize = scale;
          try { await pointMgr.update(annot); } catch (_) {}
        }
      }

      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
      }
    });
    _routeDrawTicker!.start();
    return completer.future;
  }

  /// Draw a single gold route line with progressive 60fps draw over 1 second.
  Future<void> _drawGoldGlossRoute(List<LatLng> points) async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null || points.length < 2) return;

    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    const totalMs = 1000;

    mapbox.PolylineAnnotation? mainLine;
    int lastCount = 0;

    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = createTicker((_) async {
      if (!mounted || _previewingOffer == null) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
        return;
      }

      final elapsed = stopwatch.elapsedMilliseconds;
      final progress = (elapsed / totalMs).clamp(0.0, 1.0);
      final eased = Curves.easeInOutSine.transform(progress);
      final count = (eased * points.length).round().clamp(2, points.length);

      if (count != lastCount) {
        lastCount = count;
        final subset = points.sublist(0, count);
        final coords = subset.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        final geo = mapbox.LineString(coordinates: coords);

        if (mainLine == null) {
          mainLine = await polyMgr.create(mapbox.PolylineAnnotationOptions(
            geometry: geo,
            lineColor: const Color(0xFFFFD700).toARGB32(),
            lineWidth: 5.0,
            lineJoin: mapbox.LineJoin.ROUND,
          ));
        } else {
          mainLine!.geometry = geo;
          try { await polyMgr.update(mainLine!); } catch (_) {}
        }
      }

      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        final fullCoords = points.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        final fullGeo = mapbox.LineString(coordinates: fullCoords);
        if (mainLine != null) {
          mainLine!.geometry = fullGeo;
          try { await polyMgr.update(mainLine!); } catch (_) {}
        }
        // Store for later cleanup
        _previewPickupAnnot = mainLine;
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
