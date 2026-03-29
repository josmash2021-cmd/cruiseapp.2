part of '../../screens/rider_tracking_screen.dart';

// ════════════════════════════════════════════════════════════
//  TRACKING MAP — map widget, annotations, camera, route
// ════════════════════════════════════════════════════════════

extension _RiderTrackingMapView on _RiderTrackingScreenState {

  /// Project a lat/lng onto the nearest point on the route polyline,
  /// returning the cumulative distance in meters along the route.
  double _projectOntoRoute(LatLng p) {
    if (_routePts.length < 2) return 0;
    
    double bestDist = double.infinity;
    double bestM = 0;

    for (int i = 0; i + 1 < _routePts.length; i++) {
      final a = _routePts[i];
      final b = _routePts[i + 1];
      final segStartM = _segDist[i];
      final segEndM = _segDist[i + 1];
      final segLenM = segEndM - segStartM;
      if (segLenM < 0.01) continue;

      // Convert to local coordinate system for accurate projection
      final dy = (b.latitude - a.latitude) * 111320; // meters per degree latitude
      final dx = (b.longitude - a.longitude) * 111320 * math.cos(a.latitude * math.pi / 180);
      final px = (p.longitude - a.longitude) * 111320 * math.cos(a.latitude * math.pi / 180);
      final py = (p.latitude - a.latitude) * 111320;
      
      var t = 0.0;
      if (dx != 0 || dy != 0) {
        final segLen2 = dx * dx + dy * dy;
        t = (px * dx + py * dy) / segLen2;
        t = t.clamp(0.0, 1.0);
      }
      
      final projLat = a.latitude + (b.latitude - a.latitude) * t;
      final projLng = a.longitude + (b.longitude - a.longitude) * t;
      final proj = LatLng(projLat, projLng);

      final dist = _hav(p, proj) * 1609.34; // Convert to meters
      if (dist < bestDist) {
        bestDist = dist;
        bestM = segStartM + segLenM * t;
      }
    }

    return bestM;
  }

  /// Removes all trip-related polyline and pin annotations from the map.
  Future<void> _cleanupMapAnnotations() async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr != null) {
      if (_remainingRouteAnnot != null) {
        try { await polyMgr.delete(_remainingRouteAnnot!); } catch (_) {}
        _remainingRouteAnnot = null;
      }
      if (_approachAnnot != null) {
        try { await polyMgr.delete(_approachAnnot!); } catch (_) {}
        _approachAnnot = null;
      }
    }
    final ptMgr = _pointAnnotMgr;
    if (ptMgr != null) {
      if (_pickupAnnot != null) {
        try { await ptMgr.delete(_pickupAnnot!); } catch (_) {}
        _pickupAnnot = null;
      }
      if (_dropoffAnnot != null) {
        try { await ptMgr.delete(_dropoffAnnot!); } catch (_) {}
        _dropoffAnnot = null;
      }
    }
  }


  Future<void> _loadPins() async {
    _pickupPinBytes = await _renderGoldPin(
      isPickup: true,
      label: widget.pickupLabel,
    );
    _dropoffPinBytes = await _renderGoldPin(
      isPickup: false,
      label: widget.dropoffLabel,
    );
    // Build pin+label bitmap variants for animated label reveal
    if (widget.pickupLabel.trim().isNotEmpty) {
      _pickupPinWithLabelBytes = await _renderGoldPinWithLabel(
        isPickup: true,
        label: widget.pickupLabel,
      );
    }
    if (widget.dropoffLabel.trim().isNotEmpty) {
      _dropoffPinWithLabelBytes = await _renderGoldPinWithLabel(
        isPickup: false,
        label: widget.dropoffLabel,
      );
    }
    if (mounted) {
      _setState(() {});
      // Force annotation update now that bytes are ready
      _updateAnnotations();
    }
  }
  
  Future<void> _loadCarIcon() async {
    final rideName = widget.rideName.toLowerCase();
    String carAsset;
    
    if (rideName.contains('vip') || rideName.contains('suv') || rideName.contains('suburban')) {
      carAsset = 'assets/images/car_suv.png';
    } else if (rideName.contains('sedan') || rideName.contains('premium') || rideName.contains('fusion')) {
      carAsset = 'assets/images/car_sedan.png';
    } else {
      carAsset = 'assets/images/car_economy.png';
    }
    
    try {
      final bytes = await rootBundle.load(carAsset);
      _carIconBytes = bytes.buffer.asUint8List();
      _currentCarType = carAsset;
    } catch (e) {
      // Fallback to economy if specific car not found
      try {
        final bytes = await rootBundle.load('assets/images/car_economy.png');
        _carIconBytes = bytes.buffer.asUint8List();
        _currentCarType = 'assets/images/car_economy.png';
      } catch (_) {}
    }
    
    // Also load navigation arrow icon
    await _loadArrowIcon();
    
    if (mounted) _setState(() {});
  }
  
  /// Load navigation arrow icon for centering mode
  Future<void> _loadArrowIcon() async {
    // Generate a golden arrow icon
    _arrowIconBytes = await _renderNavigationArrow();
  }
  
  /// Render a golden navigation arrow
  Future<Uint8List> _renderNavigationArrow() async {
    const double size = 100;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));
    const cx = size / 2;
    const cy = size / 2;
    const gold = Color(0xFFE8C547);
    
    // Drop shadow
    canvas.drawCircle(
      const Offset(cx, cy + 2),
      size * 0.4,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.4)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    
    // Gold circle background
    canvas.drawCircle(
      const Offset(cx, cy),
      size * 0.38,
      Paint()..color = gold,
    );
    
    // White arrow pointing up
    final arrowPath = Path()
      ..moveTo(cx, cy - size * 0.22)
      ..lineTo(cx - size * 0.18, cy + size * 0.08)
      ..lineTo(cx - size * 0.06, cy + size * 0.08)
      ..lineTo(cx - size * 0.06, cy + size * 0.22)
      ..lineTo(cx + size * 0.06, cy + size * 0.22)
      ..lineTo(cx + size * 0.06, cy + size * 0.08)
      ..lineTo(cx + size * 0.18, cy + size * 0.08)
      ..close();
    
    canvas.drawPath(
      arrowPath,
      Paint()..color = Colors.white,
    );
    
    // Inner highlight
    canvas.drawCircle(
      Offset(cx - size * 0.1, cy - size * 0.1),
      size * 0.15,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.2)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    
    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }


  /// Inicia la animación de entrada del carro - transición profesional estilo "formación"
  void _startCarEntranceAnimation() {
    if (_carEntranceStarted || _carEntranceComplete) return;
    
    _carEntranceStarted = true;
    _entranceStartTime = DateTime.now();
    
    // Animar a 60fps durante 800ms
    _entranceTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (_entranceStartTime == null) {
        timer.cancel();
        return;
      }
      
      final elapsed = DateTime.now().difference(_entranceStartTime!).inMilliseconds;
      final progress = (elapsed / _entranceDuration).clamp(0.0, 1.0);
      
      // Easing curve elástico (bounce out)
      _carEntranceProgress = _elasticOut(progress);
      
      // Redibujar el carro con la nueva escala
      _updateCarSmooth();
      
      if (progress >= 1.0) {
        _carEntranceComplete = true;
        timer.cancel();
        _entranceTimer = null;
      }
    });
  }

  /// Elastic bounce easing - para efecto "formación" profesional
  double _elasticOut(double t) {
    const p = 0.3;
    return math.pow(2.0, -10 * t) * math.sin((t - p / 4) * (2 * math.pi) / p) + 1.0;
  }

  /// Ease out cubic - para transición suave final
  double _easeOutCubic(double t) {
    return 1.0 - math.pow(1.0 - t, 3);
  }

  /// Genera imagen de sombra con efecto fade/blur
  Future<Uint8List> _generateShadowImage() async {
    const double size = 80.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, size, size));
    
    // Dibujar círculo negro difuminado (sombra)
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.4)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15);
    
    canvas.drawCircle(
      const Offset(size / 2, size / 2 + 5), // Ligeramente desplazada hacia abajo
      size * 0.35,
      shadowPaint,
    );
    
    final picture = recorder.endRecording();
    final img = picture.toImageSync(size.toInt(), size.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  /// Detect location type from address label for contextual icon
  _PinIcon _detectPinIcon(String label) {
    final l = label.toLowerCase();
    if (l.contains('airport') ||
        l.contains('terminal') ||
        RegExp(
          r'\b(mia|fll|jfk|lax|ord|atl|sfo|dfw|ewr|bos|iah|dca|phl|msp|dtw|sea|den|las|mco|clt)\b',
        ).hasMatch(l)) {
      return _PinIcon.airplane;
    }
    if (l.contains('store') ||
        l.contains('shop') ||
        l.contains('mall') ||
        l.contains('plaza') ||
        l.contains('market') ||
        l.contains('center') ||
        l.contains('restaurant') ||
        l.contains('hotel') ||
        l.contains('bar') ||
        l.contains('café') ||
        l.contains('cafe') ||
        l.contains('gym') ||
        l.contains('salon') ||
        l.contains('office') ||
        l.contains('hospital') ||
        l.contains('clinic') ||
        l.contains('bank') ||
        l.contains('pharmacy')) {
      return _PinIcon.store;
    }
    if (RegExp(r'^\d+\s').hasMatch(l) &&
        RegExp(
          r'\b(st|ave|rd|dr|ln|ct|blvd|way|pkwy|pl|cir|ter|loop)\b',
        ).hasMatch(l)) {
      return _PinIcon.house;
    }
    return _PinIcon.person;
  }

  /// Renders a circular pin with contextual icon.
  /// Uses shared circular_pin_renderer for consistent design across the app.
  Future<Uint8List> _renderGoldPin({
    required bool isPickup,
    String label = '',
  }) async {
    final iconType = _detectPinIcon(label);
    CircularPinIcon circIcon;
    switch (iconType) {
      case _PinIcon.house:    circIcon = CircularPinIcon.home; break;
      case _PinIcon.store:    circIcon = CircularPinIcon.store; break;
      case _PinIcon.airplane: circIcon = CircularPinIcon.airplane; break;
      case _PinIcon.person:   circIcon = CircularPinIcon.person; break;
    }
    return renderCircularPinBytes(icon: circIcon, isPickup: isPickup, radius: 44);
  }

  /// Renders a gold pin + address label as a single combined bitmap.
  /// The pin tip is at bottom-center for iconAnchor: BOTTOM.
  Future<Uint8List> _renderGoldPinWithLabel({
    required bool isPickup,
    required String label,
  }) async {
    // Get the standalone pin bitmap
    final pinBytes = await _renderGoldPin(isPickup: isPickup, label: label);
    final codec = await ui.instantiateImageCodec(pinBytes);
    final frame = await codec.getNextFrame();
    final pinImg = frame.image;

    // Truncate label
    String displayLabel = label;
    if (label.length > 20) {
      int cut = (label.length * 0.5).round();
      for (int i = cut; i >= 0; i--) {
        if (label[i] == ',' || label[i] == ' ') { cut = i; break; }
      }
      displayLabel = '${label.substring(0, cut).trimRight()}\u2026';
    }

    // Scale the 2x pin image to a logical display size, keeping aspect ratio.
    // Pin tip MUST land at the very bottom of the canvas for iconAnchor.BOTTOM.
    const pinDisplayW = 100.0;
    final pinDisplayH = pinDisplayW * pinImg.height / pinImg.width; // ≈110
    final canvasH = pinDisplayH; // canvas height = pin height → tip at bottom

    // Measure label text
    final textPainter = TextPainter(
      text: TextSpan(
        text: displayLabel,
        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: Colors.white),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 450);

    // Label box sizing
    const hPad = 14.0;
    const gap = 8.0;
    const dotSize = 10.0;
    final labelW = hPad + dotSize + gap + textPainter.width + hPad + 8;
    final labelH = math.min(70.0, canvasH * 0.60);
    const pinLabelGap = 8.0;

    // Pickup label on right, dropoff on left
    final labelOnLeft = !isPickup;
    final rawW = pinDisplayW + pinLabelGap + labelW;

    double pinX, labelX;
    if (labelOnLeft) {
      labelX = 0;
      pinX = labelW + pinLabelGap;
    } else {
      pinX = 0;
      labelX = pinDisplayW + pinLabelGap;
    }

    // Pad canvas so pin tip is at bottom-center
    final pinTipX = pinX + pinDisplayW / 2;
    final leftMargin = pinTipX;
    final rightMargin = rawW - pinTipX;
    final maxM = math.max(leftMargin, rightMargin);
    final leftPad = maxM - leftMargin;
    final paddedW = 2 * maxM;

    final adjPinX = pinX + leftPad;
    final adjLabelX = labelX + leftPad;
    // Label vertically centered on the pin head (≈32% from pin top)
    final pinHeadCY = pinDisplayH * 0.32;
    final labelY = (pinHeadCY - labelH / 2).clamp(0.0, canvasH - labelH);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, paddedW, canvasH));

    // Draw the pre-rendered pin image scaled to fit — tip at canvas bottom
    final srcRect = Rect.fromLTWH(0, 0, pinImg.width.toDouble(), pinImg.height.toDouble());
    final dstRect = Rect.fromLTWH(adjPinX, 0, pinDisplayW, pinDisplayH);
    canvas.drawImageRect(pinImg, srcRect, dstRect, Paint());

    // Draw label box
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(adjLabelX, labelY, labelW, labelH),
      const Radius.circular(10),
    );
    canvas.drawRRect(bgRect, Paint()..color = const Color(0xF01A1A1A));
    canvas.drawRRect(
      bgRect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.10)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    double x = adjLabelX + hPad;

    // Color dot
    canvas.drawCircle(
      Offset(x + dotSize / 2, labelY + labelH / 2),
      dotSize / 2,
      Paint()..color = isPickup ? Colors.green : const Color(0xFFE8C547),
    );
    x += dotSize + gap;

    // Address text
    textPainter.paint(canvas, Offset(x, labelY + (labelH - textPainter.height) / 2));

    final picture = recorder.endRecording();
    final img = await picture.toImage(paddedW.ceil(), canvasH.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  /// Reveal pickup label: swap bitmap + spring scale animation.
  void _revealPickupLabel() {
    if (_pickupLabelRevealed || _pickupAnnot == null || _pickupPinWithLabelBytes == null) return;
    _pickupLabelRevealed = true;
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    try {
      _pickupAnnot!.image = _pickupPinWithLabelBytes!;
      mgr.update(_pickupAnnot!);
    } catch (_) {}
    _labelSpringAnimation(_pickupAnnot!);
  }

  /// Reveal dropoff label: swap bitmap + spring scale animation.
  void _revealDropoffLabel() {
    if (_dropoffLabelRevealed || _dropoffAnnot == null || _dropoffPinWithLabelBytes == null) return;
    _dropoffLabelRevealed = true;
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    try {
      _dropoffAnnot!.image = _dropoffPinWithLabelBytes!;
      mgr.update(_dropoffAnnot!);
    } catch (_) {}
    _labelSpringAnimation(_dropoffAnnot!);
  }

  /// Spring scale animation for label reveal: 0.50 → 1.15 → 0.95 → 1.05 over 600ms.
  void _labelSpringAnimation(mapbox.PointAnnotation annot) {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    const duration = 600;
    final start = DateTime.now();
    Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (!mounted) { timer.cancel(); return; }
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      final t = (elapsed / duration).clamp(0.0, 1.0);
      double scale;
      if (t < 0.5) {
        scale = 0.50 + (1.15 - 0.50) * (t / 0.5);
      } else if (t < 0.75) {
        scale = 1.15 + (0.95 - 1.15) * ((t - 0.5) / 0.25);
      } else {
        scale = 0.95 + (1.05 - 0.95) * ((t - 0.75) / 0.25);
      }
      try {
        mgr.update(annot..iconSize = scale);
      } catch (_) {}
      if (t >= 1.0) timer.cancel();
    });
  }

  Future<void> _initRoute() async {
    // 1) Get the trip route (pickup → dropoff)
    List<LatLng> tripRoute = [];
    if (widget.routePoints != null && widget.routePoints!.isNotEmpty) {
      tripRoute = List.from(widget.routePoints!);
    } else {
      final ds = DirectionsService(ApiKeys.webServices);
      final r = await ds.getRoute(
        origin: widget.pickupLatLng,
        destination: widget.dropoffLatLng,
      );
      if (r != null && mounted) tripRoute = r.points;
    }
    if (tripRoute.isEmpty) {
      tripRoute = [widget.pickupLatLng, widget.dropoffLatLng];
    }
    // Force endpoints to exact pin coordinates
    tripRoute[0] = widget.pickupLatLng;
    tripRoute[tripRoute.length - 1] = widget.dropoffLatLng;

    // 2) Set up route — driver position comes from Firestore in real time
    _pickupIdx = 0;
    _routePts = tripRoute;

    // Build cumulative distance array
    _buildSegDist();

    // 3) Driver starts at pickup (will be updated by Firestore stream)
    _traveledM = 0;
    _tgtTraveledM = 0;
    _driverPos = widget.pickupLatLng;
    _animPos = _driverPos;

    // 4) Calculate initial distance
    // During arriving phase: show distance from pickup to driver (will update from GPS)
    // During onTrip: use full route distance
    if (_phase == _TrackPhase.arriving || _phase == _TrackPhase.arrived) {
      // Will be overridden by real GPS in _onRealDriverLocation
      _distanceMiles = 0;
      _etaMinutes = 1;
    } else {
      double acc = 0;
      for (int i = 0; i + 1 < _routePts.length; i++) {
        acc += _hav(_routePts[i], _routePts[i + 1]);
      }
      _distanceMiles = acc;
      _etaMinutes = (acc / 0.5).ceil().clamp(1, 99);
    }

    _setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _fitAllPoints();
        // Fit route bounds after short delay to allow card measurements
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) _fitRouteBounds();
        });
      }
    });
  }

  /// Fit route bounds applying precise padding for top and bottom cards.
  /// Called after layout is ready so card heights can be measured.
  /// During 'arriving' phase the driver's current animated position is included
  /// so the camera always shows the full path from driver → pickup point.
  void _fitRouteBounds() {
    if (_map == null || _routePts.isEmpty) return;
    
    // Get actual card heights from GlobalKeys
    final topHeight = _topCardHeight;
    final bottomHeight = _bottomCardHeight;
    
    // During arriving: fit driver→pickup only (no dropoff/route)
    if (_phase == _TrackPhase.arriving || _phase == _TrackPhase.arrived) {
      _fitArrivingBounds();
      return;
    }
    // During onTrip+: include pickup + dropoff + driver + route.
    final pts = <LatLng>[widget.pickupLatLng, widget.dropoffLatLng];
    if (_animPos.latitude != 0) pts.add(_animPos);
    pts.addAll(_routePts);
    
    double minLat = pts[0].latitude, maxLat = pts[0].latitude;
    double minLng = pts[0].longitude, maxLng = pts[0].longitude;
    for (final p in pts) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }
    
    // Apply card-aware padding: route always fits between top and bottom cards
    _map?.cameraForCoordinatesPadding(
      [mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
       mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat))],
      mapbox.CameraOptions(bearing: 0, pitch: 0),
      mapbox.MbxEdgeInsets(
        top: topHeight + 24,
        bottom: bottomHeight + 24,
        left: 32,
        right: 32,
      ),
      null, null,
    ).then((cam) {
      if (mounted && _map != null) _map!.setCamera(cam);
    });
  }

  void _throttleBoundsFit() {
    final now = DateTime.now();
    if (now.difference(_lastBoundsFit).inMilliseconds < 2000) return;
    _lastBoundsFit = now;
    _fitRouteBounds();
  }
  
  Future<void> _applyDarkNavyGoldTheme(mapbox.MapboxMap ctrl) async {
    await MapTheme.applyNavyGold(ctrl);
  }

  void _updateCameraForRoute() {
    if (_map == null || _routePts.isEmpty) return;
    _fitRouteBounds();
  }

  /// Blend two bearings with smooth interpolation
  double _blendBearings(double b1, double b2, double t) {
    double diff = b2 - b1;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    return (b1 + diff * t) % 360;
  }

  // ── Update camera target bounds (called from sim tick) ──
  void _throttleCam() {
    _updateCamTarget();
  }

  // ── Compute ideal bounds and set as smooth target ──
  void _updateCamTarget() {
    if (_map == null) return;
    _fitRouteBounds();
  }

  void _fitAllPoints() {
    _updateCamTarget();
  }

  void _recenter() {
    _fitRouteBounds();
  }

  double _hav(LatLng a, LatLng b) {
    const R = 3958.8;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final la = a.latitude * math.pi / 180;
    final lb = b.latitude * math.pi / 180;
    final h =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(la) * math.cos(lb) * math.sin(dLon / 2) * math.sin(dLon / 2);
    return 2 * R * math.asin(math.sqrt(h));
  }

  double _bearing(LatLng f, LatLng t) {
    final dL = (t.longitude - f.longitude) * math.pi / 180;
    final la = f.latitude * math.pi / 180;
    final lb = t.latitude * math.pi / 180;
    final y = math.sin(dL) * math.cos(lb);
    final x =
        math.cos(la) * math.sin(lb) -
        math.sin(la) * math.cos(lb) * math.cos(dL);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  /// Build cumulative distance array (meters) for the route.
  void _buildSegDist() {
    _segDist = List.filled(_routePts.length, 0.0);
    for (int i = 1; i < _routePts.length; i++) {
      _segDist[i] =
          _segDist[i - 1] + _hav(_routePts[i - 1], _routePts[i]) * 1609.34;
    }
  }

  /// Returns (position, bearing) at a given distance along the route (meters).
  /// Ultra-smooth version with enhanced interpolation for realistic rolling motion.
  (LatLng, double) _posAtDistUltraSmooth(double distM) {
    if (_routePts.isEmpty) return (const LatLng(0, 0), 0);
    if (distM <= 0) {
      return (
        _routePts.first,
        _bearing(_routePts[0], _routePts[math.min(1, _routePts.length - 1)]),
      );
    }
    final totalM = _segDist.last;
    if (distM >= totalM) return (_routePts.last, _driverBearing);

    // Binary search for exact segment
    int lo = 0, hi = _segDist.length - 1;
    while (lo < hi - 1) {
      final mid = (lo + hi) >> 1;
      if (_segDist[mid] <= distM) {
        lo = mid;
      } else {
        hi = mid;
      }
    }

    final segLen = _segDist[hi] - _segDist[lo];
    // Use smooth step interpolation for natural acceleration/deceleration
    final rawT = segLen > 0.01 ? (distM - _segDist[lo]) / segLen : 0.0;
    // Apply smoothstep curve: 3t² - 2t³ for ease-in-out effect
    final t = rawT * rawT * (3.0 - 2.0 * rawT);
    
    final a = _routePts[lo];
    final b = _routePts[hi];
    final lat = a.latitude + (b.latitude - a.latitude) * t;
    final lng = a.longitude + (b.longitude - a.longitude) * t;
    final pos = LatLng(lat, lng);

    // Enhanced bearing calculation with look-ahead for smoother turning
    // Look ahead 8 meters for more responsive but smooth turning
    final lookAhead = math.min(distM + 8, totalM);
    int llo = lo, lhi = hi;
    if (lookAhead > _segDist[hi]) {
      llo = hi;
      lhi = math.min(hi + 1, _segDist.length - 1);
      while (lhi < _segDist.length - 1 && _segDist[lhi] < lookAhead) {
        lhi++;
      }
    }
    final lookSegLen = _segDist[lhi] - _segDist[llo];
    final lookRawT = lookSegLen > 0.01
        ? (lookAhead - _segDist[llo]) / lookSegLen
        : 0.0;
    // Apply smoothstep to look-ahead as well
    final lookT = lookRawT * lookRawT * (3.0 - 2.0 * lookRawT);
    
    final la = _routePts[llo];
    final lb = _routePts[lhi];
    final lookPos = LatLng(
      la.latitude + (lb.latitude - la.latitude) * lookT,
      la.longitude + (lb.longitude - la.longitude) * lookT,
    );
    final brg = _bearing(pos, lookPos);
    return (pos, brg);
  }

  /// Returns (position, bearing) at a given distance along the route (meters).
  (LatLng, double) _posAtDist(double distM) {
    if (_routePts.isEmpty) return (const LatLng(0, 0), 0);
    if (distM <= 0) {
      return (
        _routePts.first,
        _bearing(_routePts[0], _routePts[math.min(1, _routePts.length - 1)]),
      );
    }
    final totalM = _segDist.last;
    if (distM >= totalM) return (_routePts.last, _driverBearing);

    // Binary search for segment
    int lo = 0, hi = _segDist.length - 1;
    while (lo < hi - 1) {
      final mid = (lo + hi) >> 1;
      if (_segDist[mid] <= distM) {
        lo = mid;
      } else {
        hi = mid;
      }
    }

    final segLen = _segDist[hi] - _segDist[lo];
    final t = segLen > 0.01 ? (distM - _segDist[lo]) / segLen : 0.0;
    final a = _routePts[lo];
    final b = _routePts[hi];
    final lat = a.latitude + (b.latitude - a.latitude) * t;
    final lng = a.longitude + (b.longitude - a.longitude) * t;
    final pos = LatLng(lat, lng);

    // Bearing: look ahead only ~5m so the car turns at the actual
    // curve instead of starting to rotate 30 m before it.
    final lookAhead = math.min(distM + 5, totalM);
    int llo = lo, lhi = hi;
    if (lookAhead > _segDist[hi]) {
      llo = hi;
      lhi = math.min(hi + 1, _segDist.length - 1);
      while (lhi < _segDist.length - 1 && _segDist[lhi] < lookAhead) {
        lhi++;
      }
    }
    final lt = (_segDist[lhi] - _segDist[llo]) > 0.01
        ? (lookAhead - _segDist[llo]) / (_segDist[lhi] - _segDist[llo])
        : 0.0;
    final la = _routePts[llo];
    final lb = _routePts[lhi];
    final lookPos = LatLng(
      la.latitude + (lb.latitude - la.latitude) * lt,
      la.longitude + (lb.longitude - la.longitude) * lt,
    );
    final brg = _bearing(pos, lookPos);
    return (pos, brg);
  }

  // ── Full-screen Map ──
  Widget _buildFullScreenMap() {
    return Stack(
      children: [
        RepaintBoundary(
          child: mapbox.MapWidget(
            key: const ValueKey('rider-map'),
            styleUri: MapboxConfig.styleDark,
            cameraOptions: mapbox.CameraOptions(
              center: mapbox.Point(
                coordinates: mapbox.Position(
                  widget.pickupLatLng.longitude,
                  widget.pickupLatLng.latitude,
                ),
              ),
              zoom: 14.0, pitch: 0.0,
            ),
            textureView: true,
            onMapCreated: (ctrl) async {
              _map = ctrl;
              // Lock map: disable all user gestures
              ctrl.gestures.updateSettings(mapbox.GesturesSettings(
                scrollEnabled: false,
                pinchToZoomEnabled: false,
                doubleTapToZoomInEnabled: false,
                doubleTouchToZoomOutEnabled: false,
                rotateEnabled: false,
                pitchEnabled: false,
                quickZoomEnabled: false,
              ));
              ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
              ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
              ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
              ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));
              _polylineAnnotMgr = await ctrl.annotations.createPolylineAnnotationManager(
                below: 'road-label',
              );
              _pointAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
              try {
                await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
                await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-rotation-alignment', 'viewport');
                await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-allow-overlap', true);
              } catch (_) {}
              _updateAnnotations();
            },
            onStyleLoadedListener: (_) async {
              if (_map != null) await _applyDarkNavyGoldTheme(_map!);
            },
          ),
        ),
      ],
    );
  }

  Widget _circleBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(icon, size: 20, color: Colors.white),
      ),
    );
  }


  // ── Fast path: update only the car GeoJSON (called every 60fps frame) ──
  void _updateCarSmooth() {
    if (_carUpdateInProgress) return; // skip frame if previous update still running
    if (_map == null) return;
    if (_animPos.latitude == 0 && _animPos.longitude == 0) return;
    _carUpdateInProgress = true;
    _updateCarGeoJsonOnly().whenComplete(() => _carUpdateInProgress = false);
  }

  // Update only the car/shadow GeoJSON source positions (no layer recreation)
  Future<void> _updateCarGeoJsonOnly() async {
    if (_map == null) return;
    final iconBytes = _navArrowMode && _arrowIconBytes != null ? _arrowIconBytes! : _carIconBytes;
    if (iconBytes == null) return;
    try {
      final style = _map!.style;
      final imageId = _navArrowMode ? _arrowImageId : _carImageId;
      final isArrow = _navArrowMode;

      // ── First time: add image + create source + layer ──
      if (isArrow && !_arrowImageAdded && _arrowIconBytes != null) {
        await style.addStyleImage(_arrowImageId, 1.0,
          mapbox.MbxImage(width: 100, height: 100, data: _arrowIconBytes!),
          false, [], [], null);
        _arrowImageAdded = true;
      } else if (!isArrow && !_carImageAdded && _carIconBytes != null) {
        await style.addStyleImage(_carImageId, 1.0,
          mapbox.MbxImage(width: 64, height: 64, data: _carIconBytes!),
          false, [], [], null);
        _carImageAdded = true;
        // Shadow image
        _carShadowBytes ??= await _generateShadowImage();
        if (_carShadowBytes != null && !_carShadowAdded) {
          await style.addStyleImage(_carShadowImageId, 1.0,
            mapbox.MbxImage(width: 80, height: 80, data: _carShadowBytes!),
            false, [], [], null);
          _carShadowAdded = true;
        }
      }

      final lng = _animPos.longitude;
      final lat = _animPos.latitude;
      final brg = _animBearing;
      final geoJson = '{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[$lng,$lat]},"properties":{"bearing":$brg}}]}';

      final sourceExists = await style.styleSourceExists(_carSourceId);
      if (!sourceExists) {
        // Create shadow source + layer first
        if (!isArrow && _carShadowAdded) {
          final shadowGeo = '{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[$lng,$lat]},"properties":{}}]}';
          await style.addSource(mapbox.GeoJsonSource(id: _carShadowSourceId, data: shadowGeo));
          await style.addLayer(mapbox.SymbolLayer(
            id: _carShadowLayerId, sourceId: _carShadowSourceId,
            iconImage: _carShadowImageId, iconSize: 0.7,
            iconAnchor: mapbox.IconAnchor.CENTER,
            iconAllowOverlap: true, iconIgnorePlacement: true, iconOpacity: 0.5,
          ));
        }
        // Create car source + layer
        await style.addSource(mapbox.GeoJsonSource(id: _carSourceId, data: geoJson));
        final scale = isArrow ? 1.0 : (_carEntranceProgress * _kCarScale).clamp(0.001, _kCarScale);
        await style.addLayer(mapbox.SymbolLayer(
          id: _carLayerId, sourceId: _carSourceId,
          iconImage: imageId,
          iconSize: scale,
          iconOpacity: 1.0,
          iconRotate: isArrow ? 0.0 : brg,
          iconRotationAlignment: mapbox.IconRotationAlignment.MAP,
          iconAllowOverlap: true, iconIgnorePlacement: true,
        ));
        try { await style.moveStyleLayer(_carLayerId, null); } catch (_) {}
        if (!isArrow) _startCarEntranceAnimation();
      } else {
        // ── Hot path: just update position + rotation in existing source ──
        final source = await style.getSource(_carSourceId);
        if (source != null) (source as mapbox.GeoJsonSource).updateGeoJSON(geoJson);

        final layerExists = await style.styleLayerExists(_carLayerId);
        if (layerExists) {
          await style.setStyleLayerProperty(_carLayerId, 'icon-image', imageId);
          await style.setStyleLayerProperty(_carLayerId, 'icon-rotate', isArrow ? 0.0 : brg);
          final scale = isArrow ? 1.0 : (_carEntranceProgress * _kCarScale).clamp(0.001, _kCarScale);
          await style.setStyleLayerProperty(_carLayerId, 'icon-size', scale);
          try { await style.moveStyleLayer(_carLayerId, null); } catch (_) {}
        }

        // Update shadow position
        if (!isArrow) {
          final shadowGeo = '{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[$lng,$lat]},"properties":{}}]}';
          final shadowSrc = await style.getSource(_carShadowSourceId);
          if (shadowSrc != null) (shadowSrc as mapbox.GeoJsonSource).updateGeoJSON(shadowGeo);
        }
      }
    } catch (_) {}
  }
  Future<void> _updateStaticAnnotationsOnce() async {
    if (_staticAnnotsDone) return;
    final pointMgr = _pointAnnotMgr;
    final polyMgr = _polylineAnnotMgr;
    if (pointMgr == null || polyMgr == null) return;
    if (_pickupPinBytes == null || _dropoffPinBytes == null) return;
    if (_routePts.length < 2) return;
    _staticAnnotsDone = true; // mark before await to prevent double-creation

    // Pickup pin — always visible
    try {
      _pickupAnnot ??= await pointMgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(widget.pickupLatLng.longitude, widget.pickupLatLng.latitude)),
        image: _pickupPinBytes!,
        iconSize: 1.05,
        iconAnchor: mapbox.IconAnchor.BOTTOM,
        iconOffset: [0, 0],
      ));
    } catch (_) {}

    // Dropoff pin — only visible during onTrip, not during arriving
    if (_phase != _TrackPhase.arriving && _phase != _TrackPhase.arrived) {
      _addDropoffPin();
    }

    // Cinematic intro: fit camera (no route draw during arriving)
    _startCinematicIntro();

    // Fit route bounds with card padding after drawing
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fitRouteBounds();
    });

    // Reveal pickup label after brief delay
    if (_pickupPinWithLabelBytes != null && !_pickupLabelRevealed) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        _revealPickupLabel();
      });
    }
  }

  /// Add dropoff pin (called once when phase transitions to onTrip)
  Future<void> _addDropoffPin() async {
    if (_dropoffPinAdded) return;
    final pointMgr = _pointAnnotMgr;
    if (pointMgr == null || _dropoffPinBytes == null) return;
    _dropoffPinAdded = true;
    try {
      _dropoffAnnot ??= await pointMgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(widget.dropoffLatLng.longitude, widget.dropoffLatLng.latitude)),
        image: _dropoffPinBytes!,
        iconSize: 0.01,
        iconAnchor: mapbox.IconAnchor.BOTTOM,
        iconOffset: [0, 0],
      ));
      // Animate pin pop: 0.01 → 1.15 → 0.95 → 1.05 over 500ms
      _animateDropoffPinPop();
    } catch (_) {}
  }

  /// Pin pop spring animation for dropoff pin
  void _animateDropoffPinPop() {
    if (_dropoffAnnot == null || _pointAnnotMgr == null) return;
    const duration = 500;
    final start = DateTime.now();
    Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (!mounted) { timer.cancel(); return; }
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      final t = (elapsed / duration).clamp(0.0, 1.0);
      double scale;
      if (t < 0.4) {
        scale = 0.01 + (1.15 - 0.01) * (t / 0.4);
      } else if (t < 0.7) {
        scale = 1.15 + (0.95 - 1.15) * ((t - 0.4) / 0.3);
      } else {
        scale = 0.95 + (1.05 - 0.95) * ((t - 0.7) / 0.3);
      }
      try {
        _pointAnnotMgr!.update(_dropoffAnnot!..iconSize = scale);
      } catch (_) {}
      if (t >= 1.0) {
        timer.cancel();
        // Reveal dropoff label after pin pop settles
        Future.delayed(const Duration(milliseconds: 300), () {
          if (!mounted) return;
          _revealDropoffLabel();
        });
      }
    });
  }

  /// Pop-out animation for the pickup pin when driver picks up rider.
  /// Grows to 1.6x then shrinks to 0 and removes the annotation.
  void _popOutPickupPin() {
    if (_pickupPopping || _pickupAnnot == null || _pointAnnotMgr == null) return;
    _pickupPopping = true;
    const duration = 600;
    final start = DateTime.now();
    Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (!mounted) { timer.cancel(); return; }
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      final t = (elapsed / duration).clamp(0.0, 1.0);
      double scale;
      if (t < 0.35) {
        // Grow: 1.05 → 1.6
        scale = 1.05 + (1.6 - 1.05) * (t / 0.35);
      } else {
        // Shrink: 1.6 → 0
        final st = (t - 0.35) / 0.65;
        scale = 1.6 * (1.0 - st * st); // ease-in shrink
      }
      try {
        _pointAnnotMgr!.update(_pickupAnnot!..iconSize = math.max(scale, 0.01));
      } catch (_) {}
      if (t >= 1.0) {
        timer.cancel();
        _showPickupPin = false;
        try { _pointAnnotMgr!.delete(_pickupAnnot!); } catch (_) {}
        _pickupAnnot = null;
      }
    });
  }

  /// Animated route draw: progressively reveals the 4-layer gold gloss route
  void _startAnimatedRouteDraw() {
    if (_routeDrawDone || _routePts.length < 2) return;
    _routeDrawDone = true;
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null) return;

    final allCoords = _routePts.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    final totalPts = allCoords.length;
    const drawDurationMs = 1000;
    final startTime = DateTime.now();

    // Create all 4 layers with just 2 initial points
    final initGeom = mapbox.LineString(coordinates: allCoords.sublist(0, 2));
    _createRouteLayers(polyMgr, initGeom);

    _routeDrawTicker = createTicker((_) {
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      final t = (elapsed / drawDurationMs).clamp(0.0, 1.0);
      final count = (2 + (totalPts - 2) * _easeOutCubic(t)).round().clamp(2, totalPts);
      final geom = mapbox.LineString(coordinates: allCoords.sublist(0, count));
      _updateRouteLayers(polyMgr, geom);
      if (t >= 1.0) {
        _routeDrawTicker?.stop();
      }
    })..start();
  }

  Future<void> _createRouteLayers(mapbox.PolylineAnnotationManager mgr, mapbox.LineString geom) async {
    // Single gloss gold line — clean, no glow
    try { _remainingRouteAnnot ??= await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: geom,
      lineColor: const Color(0xFFFFD700).toARGB32(),
      lineWidth: 5.0, lineJoin: mapbox.LineJoin.ROUND,
    )); } catch (_) {}
  }

  void _updateRouteLayers(mapbox.PolylineAnnotationManager mgr, mapbox.LineString geom) {
    try {
      if (_remainingRouteAnnot != null) mgr.update(_remainingRouteAnnot!..geometry = geom);
    } catch (_) {}
  }

  /// Erase the route behind the car: update remaining-route layers to show
  /// only the portion ahead of the current driver position.
  void _eraseRouteBehindCar() {
    final now = DateTime.now();
    if (now.difference(_lastRouteErase).inMilliseconds < 500) return;
    _lastRouteErase = now;

    final mgr = _polylineAnnotMgr;
    if (mgr == null || _segDist.isEmpty || _routePts.length < 2) return;
    if (_remainingRouteAnnot == null) return;

    final dist = _traveledM;
    if (dist <= 0) return; // nothing to erase yet

    // Binary search for the segment the driver is on
    int lo = 0, hi = _segDist.length - 1;
    while (lo < hi - 1) {
      final mid = (lo + hi) >> 1;
      if (_segDist[mid] <= dist) {
        lo = mid;
      } else {
        hi = mid;
      }
    }

    // Interpolate exact position on current segment
    final segLen = _segDist[hi] - _segDist[lo];
    final t = segLen > 0.01 ? ((dist - _segDist[lo]) / segLen).clamp(0.0, 1.0) : 0.0;
    final a = _routePts[lo];
    final b = _routePts[hi];
    final curLat = a.latitude + (b.latitude - a.latitude) * t;
    final curLng = a.longitude + (b.longitude - a.longitude) * t;

    // Build remaining coords: interpolated current point + all points ahead
    final remaining = <mapbox.Position>[
      mapbox.Position(curLng, curLat),
      ...List.generate(
        _routePts.length - hi,
        (i) => mapbox.Position(_routePts[hi + i].longitude, _routePts[hi + i].latitude),
      ),
    ];
    if (remaining.length < 2) return;

    final geom = mapbox.LineString(coordinates: remaining);
    try {
      if (_remainingRouteAnnot != null) mgr.update(_remainingRouteAnnot!..geometry = geom);
    } catch (_) {}
  }
  void _updateApproachLine() {
    // Throttle: update every 500ms
    final now = DateTime.now();
    if (now.difference(_lastApproachUpdate).inMilliseconds < 500) return;
    _lastApproachUpdate = now;

    final mgr = _polylineAnnotMgr;
    if (mgr == null) return;

    // Only show during arriving phase, when driver is far from pickup
    final distToPickup = _hav(_animPos, widget.pickupLatLng) * 1609.34; // meters
    final shouldShow = _phase == _TrackPhase.arriving && distToPickup > 200;

    if (!shouldShow) {
      // Remove existing approach line
      if (_approachAnnot != null && !_approachLineRemoved) {
        _approachLineRemoved = true;
        try { mgr.delete(_approachAnnot!); } catch (_) {}
        _approachAnnot = null;
      }
      return;
    }

    final geom = mapbox.LineString(coordinates: [
      mapbox.Position(_animPos.longitude, _animPos.latitude),
      mapbox.Position(widget.pickupLatLng.longitude, widget.pickupLatLng.latitude),
    ]);

    if (_approachAnnot == null) {
      // Create approach line: thin, faint gold, dashed feel via low opacity
      mgr.create(mapbox.PolylineAnnotationOptions(
        geometry: geom,
        lineColor: const Color(0xFFD4AF37).withValues(alpha: 0.35).toARGB32(),
        lineWidth: 2.5,
        lineJoin: mapbox.LineJoin.ROUND,
      )).then((annot) { _approachAnnot = annot; }).catchError((_) {});
    } else {
      try { mgr.update(_approachAnnot!..geometry = geom); } catch (_) {}
    }
  }

  /// Map intro: fit camera flat.
  /// Route polyline is NOT drawn during arriving phase — only when ride starts.
  Future<void> _startCinematicIntro() async {
    if (_cinematicDone || _map == null) return;
    _cinematicDone = true;

    // Keep camera flat always
    _cinematicPitch = 0;
    _cinematicBearing = 0;

    // Fit camera to driver → pickup (not full route) during arriving
    _fitArrivingBounds();
  }

  void _applyCinematicCamera() {
    // No-op: camera stays top-down always
  }

  /// Fit camera to show driver → pickup during arriving phase.
  void _fitArrivingBounds() {
    if (_map == null) return;
    final pts = <LatLng>[widget.pickupLatLng];
    if (_animPos.latitude != 0) pts.add(_animPos);
    if (pts.length < 2) pts.add(widget.pickupLatLng); // fallback

    double minLat = pts[0].latitude, maxLat = pts[0].latitude;
    double minLng = pts[0].longitude, maxLng = pts[0].longitude;
    for (final p in pts) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }
    _map?.cameraForCoordinatesPadding(
      [mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
       mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat))],
      mapbox.CameraOptions(bearing: 0, pitch: 0, zoom: 15.0),
      mapbox.MbxEdgeInsets(top: _topCardHeight + 24, left: 50, bottom: _bottomCardHeight + 24, right: 50),
      null, null,
    ).then((cam) {
      if (mounted && _map != null) {
        _map!.flyTo(cam, mapbox.MapAnimationOptions(duration: 600));
      }
    });
  }

  /// ──────────────────────────────────────────────────────────────────────────
  /// FIX 2: DRIVER ARRIVED STATE
  /// ──────────────────────────────────────────────────────────────────────────
  
  /// Handle driver arrival: fade route, zoom camera to driver location
  Future<void> _handleDriverArrived() async {
    if (_arrivedStateInitialized || _map == null) return;
    _arrivedStateInitialized = true;

    // STEP 1: Fade out the route polyline over 600ms
    const fadeDuration = 600;
    final startTime = DateTime.now();
    _routeFadeTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) async {
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      final t = (elapsed / fadeDuration).clamp(0.0, 1.0);
      _routeOpacity = 1.0 - t; // fade from 1.0 to 0.0
      
      // Update route polyline opacity if it exists
      if (_remainingRouteAnnot != null && _polylineAnnotMgr != null) {
        try {
          final newOpacity = _routeOpacity;
          _polylineAnnotMgr!.update(
            _remainingRouteAnnot!..lineOpacity = newOpacity,
          );
        } catch (_) {}
      }
      
      if (t >= 1.0) {
        timer.cancel();
        _routeFadeTimer = null;
        // Remove route annotation entirely after fade completes
        if (_remainingRouteAnnot != null && _polylineAnnotMgr != null) {
          try { 
            await _polylineAnnotMgr!.delete(_remainingRouteAnnot!); 
          } catch (_) {}
          _remainingRouteAnnot = null;
        }
        // Remove destination pin as well
        if (_dropoffAnnot != null && _pointAnnotMgr != null) {
          try { 
            await _pointAnnotMgr!.delete(_dropoffAnnot!); 
          } catch (_) {}
          _dropoffAnnot = null;
        }
      }
    });

    // STEP 2: Animate camera to zoom in on driver location
    // Zoom to 16.5 with 20 degree tilt
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_map == null || !mounted) return;
      _map?.cameraForCoordinatesPadding(
        [mapbox.Point(coordinates: mapbox.Position(_animPos.longitude, _animPos.latitude))],
        mapbox.CameraOptions(bearing: 0, pitch: 0.0, zoom: 16.5),
        mapbox.MbxEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
        null, null,
      ).then((cam) {
        if (_map != null && mounted) {
          _map!.flyTo(cam, mapbox.MapAnimationOptions(duration: 800));
        }
      });
    });

    // Remove approach line if it exists
    if (_approachAnnot != null && _polylineAnnotMgr != null) {
      try { await _polylineAnnotMgr!.delete(_approachAnnot!); } catch (_) {}
      _approachAnnot = null;
    }
  }

  /// Fade and remove the route polyline (for arrived state)
  Future<void> _fadeAndRemoveRoute() async {
    // This is handled by _handleDriverArrived
  }

  Future<void> _updateAnnotations() async {
    _updateCarSmooth();
    await _updateStaticAnnotationsOnce();
  }
}
