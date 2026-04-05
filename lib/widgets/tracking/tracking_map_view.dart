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
      if (_dimmedRouteAnnot != null) {
        try { await polyMgr.delete(_dimmedRouteAnnot!); } catch (_) {}
        _dimmedRouteAnnot = null;
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
      final pngBytes = await rootBundle.load(carAsset);
      final decoded = await _decodePngToRgba(pngBytes.buffer.asUint8List());
      if (decoded != null) {
        _carIconBytes = decoded.$1;
        _carIconWidth = decoded.$2;
        _carIconHeight = decoded.$3;
      }
      _currentCarType = carAsset;
    } catch (e) {
      // Fallback to economy if specific car not found
      try {
        final pngBytes = await rootBundle.load('assets/images/car_economy.png');
        final decoded = await _decodePngToRgba(pngBytes.buffer.asUint8List());
        if (decoded != null) {
          _carIconBytes = decoded.$1;
          _carIconWidth = decoded.$2;
          _carIconHeight = decoded.$3;
        }
        _currentCarType = 'assets/images/car_economy.png';
      } catch (_) {}
    }

    // Also load navigation arrow icon
    await _loadArrowIcon();

    if (mounted) _setState(() {});
  }

  /// Decode PNG bytes to raw RGBA pixel data for MbxImage.
  Future<(Uint8List, int, int)?> _decodePngToRgba(Uint8List pngBytes) async {
    final codec = await ui.instantiateImageCodec(pngBytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final byteData = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return null;
    return (byteData.buffer.asUint8List(), img.width, img.height);
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
    final byteData = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return Uint8List(0);
    return byteData.buffer.asUint8List();
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
    final byteData = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return Uint8List(0);
    return byteData.buffer.asUint8List();
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
      case _PinIcon.person:
        // Default: pickup → person icon, dropoff → flag icon
        circIcon = isPickup ? CircularPinIcon.person : CircularPinIcon.flag;
        break;
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
    _labelAnimTimer?.cancel();
    _labelAnimTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
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
    // Do NOT force raw pin coordinates — Mapbox Directions API already
    // snaps start/end to the nearest road. Replacing them with the user's
    // raw tap coordinates creates off-road straight-line segments.

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
  /// During onTrip: adaptive zoom — short routes show full remaining route,
  /// long routes show driver + enough ahead to see well (not zoomed out too far).
  void _fitRouteBounds() {
    if (_map == null || _routePts.isEmpty) return;
    
    // Get actual card heights from GlobalKeys
    final topHeight = _topCardHeight;
    final bottomHeight = _bottomCardHeight;
    
    // Safe-area insets + card offsets from rider_tracking_screen build()
    final mq = MediaQuery.of(context).padding;
    final topPad = mq.top;   // safe area top
    final bottomPad = mq.bottom; // safe area bottom
    
    final pts = <LatLng>[];
    final isOnTrip = _phase == _TrackPhase.onTrip || _phase == _TrackPhase.nearDestination;
    
    if (isOnTrip && _animPos.latitude != 0) {
      // Adaptive: compute remaining distance to dropoff
      final remainMiles = _distanceMiles;
      
      if (remainMiles <= 2.5) {
        // Short routes (< 2.5 mi): show full remaining route (driver → dropoff)
        pts.add(_animPos);
        pts.add(widget.dropoffLatLng);
        if (_segDist.isNotEmpty) {
          for (int i = 0; i < _routePts.length; i++) {
            if (_segDist[i] >= _traveledM) {
              pts.add(_routePts[i]);
            }
          }
        }
      } else {
        // Long routes (> 2.5 mi): show driver + next ~2 miles of route ahead
        // This keeps the view readable instead of zooming way out
        pts.add(_animPos);
        final targetAheadM = _traveledM + 3200; // ~2 miles ahead
        final capM = _segDist.isNotEmpty ? _segDist.last : double.infinity;
        if (_segDist.isNotEmpty) {
          for (int i = 0; i < _routePts.length; i++) {
            if (_segDist[i] >= _traveledM && _segDist[i] <= targetAheadM.clamp(0, capM)) {
              pts.add(_routePts[i]);
            }
          }
        }
        // Always include a point toward dropoff direction for context
        if (pts.length < 2) {
          pts.add(widget.dropoffLatLng);
        }
      }
    } else {
      // Overview: show full route (pickup + dropoff + driver + all route pts)
      pts.add(widget.pickupLatLng);
      pts.add(widget.dropoffLatLng);
      if (_animPos.latitude != 0) pts.add(_animPos);
      pts.addAll(_routePts);
    }
    
    if (pts.isEmpty) return;
    
    double minLat = pts[0].latitude, maxLat = pts[0].latitude;
    double minLng = pts[0].longitude, maxLng = pts[0].longitude;
    for (final p in pts) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }
    
    // Padding = safe area + card offset + card height + generous breathing room
    // Top card: positioned at topPad + 10, height = topHeight
    // Bottom card: positioned at bottomPad + 16, height = bottomHeight
    _map?.cameraForCoordinatesPadding(
      [mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
       mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat))],
      mapbox.CameraOptions(bearing: 0, pitch: 0),
      mapbox.MbxEdgeInsets(
        top: topPad + 10 + topHeight + 48,
        bottom: bottomPad + 16 + bottomHeight + 48,
        left: 44,
        right: 44,
      ),
      null, null,
    ).then((cam) {
      if (!mounted || _map == null) return;
      // Clamp zoom: min 13 (not too far), max 16 (not too close)
      final zoom = (cam.zoom ?? 14.0).clamp(13.0, 16.0);
      final clampedCam = mapbox.CameraOptions(
        center: cam.center,
        zoom: zoom,
        bearing: cam.bearing,
        pitch: cam.pitch,
        padding: cam.padding,
        anchor: cam.anchor,
      );
      // Use easeTo for smooth continuous updates during trip
      if (isOnTrip) {
        _map!.easeTo(clampedCam, mapbox.MapAnimationOptions(duration: 1200));
      } else {
        _map!.flyTo(clampedCam, mapbox.MapAnimationOptions(duration: 800));
      }
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
    final now = DateTime.now();
    if (now.difference(_lastBoundsFit).inMilliseconds < 2000) return;
    _lastBoundsFit = now;
    // Chase mode: follow driver with close-up camera
    if (_shouldFollowDriver && _animPos.latitude != 0) {
      _followDriver(_animPos, _animBearing);
      return;
    }
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
    // Linear interpolation along segments — smoothstep was causing
    // micro-stutters at segment boundaries. The exponential decay in
    // _interpolate() already provides all the easing we need.
    final t = segLen > 0.01 ? (distM - _segDist[lo]) / segLen : 0.0;

    final a = _routePts[lo];
    final b = _routePts[hi];
    final lat = a.latitude + (b.latitude - a.latitude) * t;
    final lng = a.longitude + (b.longitude - a.longitude) * t;
    final pos = LatLng(lat, lng);

    // Look ahead 18 meters for realistic turn anticipation — car nose
    // starts rotating into turns early, like a real driver steering.
    final lookAhead = math.min(distM + 18, totalM);
    int llo = lo, lhi = hi;
    if (lookAhead > _segDist[hi]) {
      llo = hi;
      lhi = math.min(hi + 1, _segDist.length - 1);
      while (lhi < _segDist.length - 1 && _segDist[lhi] < lookAhead) {
        lhi++;
      }
    }
    final lookSegLen = _segDist[lhi] - _segDist[llo];
    final lookT = lookSegLen > 0.01
        ? (lookAhead - _segDist[llo]) / lookSegLen
        : 0.0;

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
                await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-ignore-placement', true);
                await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-anchor', 'bottom');
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
    if (_map == null) return;
    if (_animPos.latitude == 0 && _animPos.longitude == 0) return;

    final lng = _animPos.longitude;
    final lat = _animPos.latitude;
    final brg = _animBearing;

    // ── Sync hot path: zero async overhead when sources are cached ──
    if (_cachedCarSource != null) {
      try {
        final geoJson = '{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[$lng,$lat]},"properties":{"bearing":$brg}}]}';
        _cachedCarSource!.updateGeoJSON(geoJson);
        if (!_navArrowMode && _cachedShadowSource != null) {
          _cachedShadowSource!.updateGeoJSON(
            '{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[$lng,$lat]},"properties":{}}]}',
          );
        }
      } catch (_) {
        // Stale source (e.g. map style reload) — clear cache, re-create next frame
        _cachedCarSource = null;
        _cachedShadowSource = null;
        _carImageAdded = false;
        _carShadowAdded = false;
        _lastNavArrowModeRendered = !_navArrowMode; // force re-init
      }
      // Only do async layer-property updates when something actually changes
      final needsAsync = !_carEntranceComplete || (_navArrowMode != _lastNavArrowModeRendered);
      if (needsAsync && !_carLayerPropsUpdating) {
        _carLayerPropsUpdating = true;
        _updateCarLayerProperties().whenComplete(() => _carLayerPropsUpdating = false);
      }
      return;
    }

    // First-time setup or recovery path (async)
    if (_carUpdateInProgress) return;
    _carUpdateInProgress = true;
    _updateCarGeoJsonOnly()
        .then((_) => _carUpdateInProgress = false)
        .catchError((_) => _carUpdateInProgress = false);
  }

  // Handles first-time source/layer creation and caches source references for the sync hot path.
  Future<void> _updateCarGeoJsonOnly() async {
    if (_map == null) return;
    final iconBytes = _navArrowMode && _arrowIconBytes != null ? _arrowIconBytes! : _carIconBytes;
    if (iconBytes == null) return;
    try {
      final style = _map!.style;
      final imageId = _navArrowMode ? _arrowImageId : _carImageId;
      final isArrow = _navArrowMode;
      final lng = _animPos.longitude;
      final lat = _animPos.latitude;
      final brg = _animBearing;
      final geoJson = '{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[$lng,$lat]},"properties":{"bearing":$brg}}]}';

      // ── Add images if not yet added ──
      if (isArrow && !_arrowImageAdded && _arrowIconBytes != null) {
        await style.addStyleImage(_arrowImageId, 1.0,
          mapbox.MbxImage(width: 100, height: 100, data: _arrowIconBytes!),
          false, [], [], null);
        _arrowImageAdded = true;
      } else if (!isArrow && !_carImageAdded && _carIconBytes != null) {
        await style.addStyleImage(_carImageId, 1.0,
          mapbox.MbxImage(width: _carIconWidth, height: _carIconHeight, data: _carIconBytes!),
          false, [], [], null);
        _carImageAdded = true;
        _carShadowBytes ??= await _generateShadowImage();
        if (_carShadowBytes != null && !_carShadowAdded) {
          await style.addStyleImage(_carShadowImageId, 1.0,
            mapbox.MbxImage(width: 80, height: 80, data: _carShadowBytes!),
            false, [], [], null);
          _carShadowAdded = true;
        }
      }

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
        final scale = isArrow ? 1.0 : (_carEntranceProgress * _kCarScale).clamp(0.001, _kCarScale);
        await style.addSource(mapbox.GeoJsonSource(id: _carSourceId, data: geoJson));
        await style.addLayer(mapbox.SymbolLayer(
          id: _carLayerId, sourceId: _carSourceId,
          iconImage: imageId,
          iconSize: scale,
          iconOpacity: 1.0,
          iconRotate: brg,
          iconRotationAlignment: mapbox.IconRotationAlignment.MAP,
          iconAllowOverlap: true, iconIgnorePlacement: true,
        ));
        // Data-driven bearing: rotation is driven by GeoJSON properties — no per-frame async call needed
        if (!isArrow) {
          await style.setStyleLayerProperty(_carLayerId, 'icon-rotate', ['get', 'bearing']);
        }
        try { await style.moveStyleLayer(_carLayerId, null); } catch (_) {}
        if (!isArrow) _startCarEntranceAnimation();
        _lastRenderedScale = scale;
        _lastNavArrowModeRendered = isArrow;
      }

      // Cache source references for the sync fast path
      final src = await style.getSource(_carSourceId);
      if (src != null) _cachedCarSource = src as mapbox.GeoJsonSource;
      if (!isArrow) {
        final shadowSrc = await style.getSource(_carShadowSourceId);
        if (shadowSrc != null) _cachedShadowSource = shadowSrc as mapbox.GeoJsonSource;
      }
    } catch (_) {}
  }

  /// Update layer visual properties — icon-size during entrance animation, icon-image on mode change.
  /// Only called when something actually changes (not every 60fps frame).
  Future<void> _updateCarLayerProperties() async {
    if (_map == null) return;
    try {
      final style = _map!.style;
      final isArrow = _navArrowMode;
      final imageId = isArrow ? _arrowImageId : _carImageId;
      final scale = isArrow ? 1.0 : (_carEntranceProgress * _kCarScale).clamp(0.001, _kCarScale);

      if (isArrow != _lastNavArrowModeRendered) {
        await style.setStyleLayerProperty(_carLayerId, 'icon-image', imageId);
        // Data expression for car bearing, static 0 for arrow
        await style.setStyleLayerProperty(
          _carLayerId, 'icon-rotate', isArrow ? 0.0 : ['get', 'bearing'],
        );
        _lastNavArrowModeRendered = isArrow;
      }
      if ((scale - _lastRenderedScale).abs() > 0.001) {
        await style.setStyleLayerProperty(_carLayerId, 'icon-size', scale);
        _lastRenderedScale = scale;
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

    // ── Draw dimmed full route (pickup→dropoff) always visible ──
    final allCoords = _routePts.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    try {
      _dimmedRouteAnnot ??= await polyMgr.create(mapbox.PolylineAnnotationOptions(
        geometry: mapbox.LineString(coordinates: allCoords),
        lineColor: const Color(0xFFFFD700).withValues(alpha: 0.20).toARGB32(),
        lineWidth: 5.0,
        lineJoin: mapbox.LineJoin.ROUND,
      ));
    } catch (_) {}

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

    // Dropoff pin — always visible from start
    _addDropoffPin();

    // Cinematic intro: fit camera
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
    // Reveal dropoff label after brief delay
    if (_dropoffPinWithLabelBytes != null && !_dropoffLabelRevealed) {
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (!mounted) return;
        _revealDropoffLabel();
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
    _dropoffPopTimer?.cancel();
    _dropoffPopTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
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
    _pickupPopOutTimer?.cancel();
    _pickupPopOutTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
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

  /// Animated route draw: progressively reveals the gold route line to dropoff
  Future<void> _startAnimatedRouteDraw() async {
    if (_routeDrawDone || _routePts.length < 2) return;
    _routeDrawDone = true;
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null) return;

    // Delete any existing route annotation so we draw fresh
    if (_remainingRouteAnnot != null) {
      try { polyMgr.delete(_remainingRouteAnnot!); } catch (_) {}
      _remainingRouteAnnot = null;
    }

    final allCoords = _routePts.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    final totalPts = allCoords.length;

    // ── Compute cumulative distances for smooth distance-based interpolation ──
    final cumDist = <double>[0.0];
    for (int i = 1; i < totalPts; i++) {
      final prev = allCoords[i - 1];
      final cur = allCoords[i];
      final dx = cur.lng.toDouble() - prev.lng.toDouble();
      final dy = cur.lat.toDouble() - prev.lat.toDouble();
      cumDist.add(cumDist.last + math.sqrt(dx * dx + dy * dy));
    }
    final totalDist = cumDist.last;
    if (totalDist < 0.00001) return;

    // Duration: smooth fluid drawing — not too fast
    final drawDurationMs = (totalPts * 10).clamp(1800, 3500);

    // Pre-create annotation BEFORE starting ticker to avoid race condition
    final initGeom = mapbox.LineString(coordinates: allCoords.sublist(0, 2));
    await _createRouteLayers(polyMgr, initGeom);
    if (!mounted || _remainingRouteAnnot == null) return;

    final stopwatch = Stopwatch()..start();
    bool updating = false;
    double lastFrac = 0.0;

    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = createTicker((_) {
      if (updating) return;
      final elapsed = stopwatch.elapsedMilliseconds;
      final t = (elapsed / drawDurationMs).clamp(0.0, 1.0);
      // Smooth S-curve: slow start, fast middle, gentle end — like water flowing
      final eased = t < 0.5
          ? 4 * t * t * t
          : 1 - math.pow(-2 * t + 2, 3) / 2;
      final targetDist = eased * totalDist;

      // Skip if barely moved (avoid unnecessary updates)
      if ((eased - lastFrac).abs() < 0.003 && t < 1.0) return;
      lastFrac = eased;

      // ── Find exact interpolated position on route at targetDist ──
      int seg = 0;
      for (int i = 1; i < totalPts; i++) {
        if (cumDist[i] >= targetDist) { seg = i - 1; break; }
        if (i == totalPts - 1) seg = i - 1;
      }
      final segLen = cumDist[seg + 1] - cumDist[seg];
      final frac = segLen > 0.00001 ? (targetDist - cumDist[seg]) / segLen : 1.0;

      // Interpolated tip point — this is what makes it flow like water
      final a = allCoords[seg];
      final b = allCoords[seg + 1];
      final tipLng = a.lng.toDouble() + (b.lng.toDouble() - a.lng.toDouble()) * frac;
      final tipLat = a.lat.toDouble() + (b.lat.toDouble() - a.lat.toDouble()) * frac;

      // Build coords: all full segments + interpolated tip
      final coords = <mapbox.Position>[
        ...allCoords.sublist(0, seg + 1),
        mapbox.Position(tipLng, tipLat),
      ];

      if (coords.length < 2) return;
      final geom = mapbox.LineString(coordinates: coords);
      updating = true;
      try {
        _remainingRouteAnnot!.geometry = geom;
        polyMgr.update(_remainingRouteAnnot!).then((_) => updating = false).catchError((_) => updating = false);
      } catch (_) { updating = false; }

      if (t >= 1.0) {
        // Final: set full route to ensure no rounding gaps
        _remainingRouteAnnot!.geometry = mapbox.LineString(coordinates: allCoords);
        polyMgr.update(_remainingRouteAnnot!).catchError((_) {});
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
    final ahead = hi < _routePts.length ? _routePts.length - hi : 0;
    final remaining = <mapbox.Position>[
      mapbox.Position(curLng, curLat),
      ...List.generate(
        ahead,
        (i) => mapbox.Position(_routePts[hi + i].longitude, _routePts[hi + i].latitude),
      ),
    ];
    if (remaining.length < 2) return;

    final geom = mapbox.LineString(coordinates: remaining);
    try {
      if (_remainingRouteAnnot != null) mgr.update(_remainingRouteAnnot!..geometry = geom);
    } catch (_) {}
  }

  /// Remove the dimmed route (called when transitioning to onTrip gloss route)
  void _removeDimmedRoute() {
    final mgr = _polylineAnnotMgr;
    if (mgr == null || _dimmedRouteAnnot == null) return;
    try { mgr.delete(_dimmedRouteAnnot!); } catch (_) {}
    _dimmedRouteAnnot = null;
  }

  void _updateApproachLine() {
    // Throttle: update every 500ms
    final now = DateTime.now();
    if (now.difference(_lastApproachUpdate).inMilliseconds < 500) return;
    _lastApproachUpdate = now;

    final mgr = _polylineAnnotMgr;
    if (mgr == null) return;

    // Only show during arriving phase
    final shouldShow = _phase == _TrackPhase.arriving;

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
      // Gloss gold line (matches main route style) from driver → pickup
      mgr.create(mapbox.PolylineAnnotationOptions(
        geometry: geom,
        lineColor: const Color(0xFFFFD700).toARGB32(),
        lineWidth: 5.0,
        lineJoin: mapbox.LineJoin.ROUND,
      )).then((annot) { _approachAnnot = annot; }).catchError((_) {});
    } else {
      try { mgr.update(_approachAnnot!..geometry = geom); } catch (_) {}
    }
  }

  /// Map intro: fit camera to show full route overview (no animation).
  Future<void> _startCinematicIntro() async {
    if (_cinematicDone || _map == null) return;
    _cinematicDone = true;

    _cinematicPitch = 0;
    _cinematicBearing = 0;

    // Fit camera to full route overview
    _fitRouteBounds();

    // Progressively draw the gold route on top of the dimmed background
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _startAnimatedRouteDraw();
    });
  }

  void _applyCinematicCamera() {
    // No-op: camera stays top-down always
  }

  /// Fit camera to show full route overview (delegates to _fitRouteBounds).
  void _fitArrivingBounds() {
    _fitRouteBounds();
  }

  /// ──────────────────────────────────────────────────────────────────────────
  /// FIX 2: DRIVER ARRIVED STATE
  /// ──────────────────────────────────────────────────────────────────────────
  
  /// Handle driver arrival: fade route, zoom camera to driver location
  Future<void> _handleDriverArrived() async {
    if (_arrivedStateInitialized || _map == null) return;
    _arrivedStateInitialized = true;

    // STEP 1: Fade out the route polyline over 600ms
    _routeFadeTimer?.cancel();
    const fadeDuration = 600;
    final startTime = DateTime.now();
    _routeFadeTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) async {
      if (!mounted) { timer.cancel(); _routeFadeTimer = null; return; }
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      final t = (elapsed / fadeDuration).clamp(0.0, 1.0);
      _routeOpacity = 1.0 - t;

      if (_remainingRouteAnnot != null && _polylineAnnotMgr != null) {
        try {
          _polylineAnnotMgr!.update(
            _remainingRouteAnnot!..lineOpacity = _routeOpacity,
          );
        } catch (_) {}
      }

      if (t >= 1.0) {
        timer.cancel();
        _routeFadeTimer = null;
        if (!mounted) return;
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
          _dropoffPinAdded = false;
        }
      }
    });

    // STEP 2: Center map on driver in the visible area between top and bottom cards.
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_map == null || !mounted) return;
      _centerDriverOnArrival();
    });

    // Remove approach line if it exists
    if (_approachAnnot != null && _polylineAnnotMgr != null) {
      try { await _polylineAnnotMgr!.delete(_approachAnnot!); } catch (_) {}
      _approachAnnot = null;
    }
  }

  Future<void> _centerDriverOnArrival() async {
    if (_map == null) return;
    final point = mapbox.Point(
      coordinates: mapbox.Position(_animPos.longitude, _animPos.latitude),
    );
    final mq = MediaQuery.of(context).padding;
    final topInset = mq.top + 10 + _topCardHeight + 48;
    final bottomInset = mq.bottom + 16 + _bottomCardHeight + 48;
    try {
      final cam = await _map!.cameraForCoordinatesPadding(
        [point],
        mapbox.CameraOptions(zoom: 16.4, bearing: 0, pitch: 0),
        mapbox.MbxEdgeInsets(
          top: topInset,
          bottom: bottomInset,
          left: 28,
          right: 28,
        ),
        null,
        null,
      );
      await _map!.flyTo(cam, mapbox.MapAnimationOptions(duration: 650));
    } catch (_) {
      await _map!.flyTo(
        mapbox.CameraOptions(center: point, zoom: 16.4, bearing: 0, pitch: 0),
        mapbox.MapAnimationOptions(duration: 650),
      );
    }
  }

  /// Fade and remove the route polyline (for arrived state)
  Future<void> _fadeAndRemoveRoute() async {
    // This is handled by _handleDriverArrived
  }

  /// Animate camera to 45° locked nav follow centred on driver position.
  /// Called during the ride-start animation sequence (Phase 4).
  void _flyToDriverAt45() {
    if (_map == null) return;
    final bearing = _animBearing;
    final mq = MediaQuery.of(context).padding;
    final topInset = mq.top + 10 + _topCardHeight + 48;
    final bottomInset = mq.bottom + 16 + _bottomCardHeight + 48;
    _map!.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(
          coordinates:
              mapbox.Position(_animPos.longitude, _animPos.latitude),
        ),
        zoom: 16.5,
        bearing: bearing,
        pitch: 45.0,
        padding: mapbox.MbxEdgeInsets(
          top: topInset,
          bottom: bottomInset,
          left: 40,
          right: 40,
        ),
      ),
      mapbox.MapAnimationOptions(duration: 1500),
    );
  }

  /// Fade out route polyline over 600 ms then clear it so it can be redrawn.
  /// Unlike [_handleDriverArrived], this does NOT remove the dropoff pin.
  void _fadeRouteForRideStart() {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null) return;

    _routeFadeTimer?.cancel();
    const fadeDuration = 600;
    final startTime = DateTime.now();
    _routeFadeTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) async {
      if (!mounted) { timer.cancel(); _routeFadeTimer = null; return; }
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      final t = (elapsed / fadeDuration).clamp(0.0, 1.0);
      final opacity = 1.0 - t;

      if (_remainingRouteAnnot != null) {
        try {
          polyMgr.update(_remainingRouteAnnot!..lineOpacity = opacity);
        } catch (_) {}
      }

      if (t >= 1.0) {
        timer.cancel();
        _routeFadeTimer = null;
        if (!mounted) return;
        if (_remainingRouteAnnot != null) {
          try {
            await polyMgr.delete(_remainingRouteAnnot!);
          } catch (_) {}
          _remainingRouteAnnot = null;
        }
        _routeDrawDone = false;
      }
    });
  }

  Future<void> _updateAnnotations() async {
    _updateCarSmooth();
    await _updateStaticAnnotationsOnce();
  }
}
