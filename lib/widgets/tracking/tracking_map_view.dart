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
        try { await polyMgr.delete(_remainingRouteAnnot!); } catch (e) {
          debugPrint('[TrackingMap] Failed to delete route annotation: $e');
        }
        _remainingRouteAnnot = null;
      }
      if (_dimmedRouteAnnot != null) {
        try { await polyMgr.delete(_dimmedRouteAnnot!); } catch (e) {
          debugPrint('[TrackingMap] Failed to delete dimmed route: $e');
        }
        _dimmedRouteAnnot = null;
      }
      if (_approachAnnot != null) {
        try { await polyMgr.delete(_approachAnnot!); } catch (e) {
          debugPrint('[TrackingMap] Failed to delete approach annotation: $e');
        }
        _approachAnnot = null;
      }
    }
    final carMgr = _carAnnotMgr;
    if (carMgr != null && _carAnnot != null) {
      try { await carMgr.delete(_carAnnot!); } catch (e) {
        debugPrint('[TrackingMap] Failed to delete car annotation: $e');
      }
      _carAnnot = null;
    }
    final ptMgr = _pointAnnotMgr;
    if (ptMgr != null) {
      if (_pickupAnnot != null) {
        try { await ptMgr.delete(_pickupAnnot!); } catch (e) {
          debugPrint('[TrackingMap] Failed to delete pickup annotation: $e');
        }
        _pickupAnnot = null;
      }
      if (_dropoffAnnot != null) {
        try { await ptMgr.delete(_dropoffAnnot!); } catch (e) {
          debugPrint('[TrackingMap] Failed to delete dropoff annotation: $e');
        }
        _dropoffAnnot = null;
      }
    }
  }


  Future<void> _loadPins() async {
    try {
      _pickupPinBytes = await _renderGoldPin(
        isPickup: true,
        label: widget.pickupLabel,
      );
    } catch (e) {
      debugPrint('[TrackingMap] Failed to render pickup pin: $e');
    }
    try {
      _dropoffPinBytes = await _renderGoldPin(
        isPickup: false,
        label: widget.dropoffLabel,
      );
    } catch (e) {
      debugPrint('[TrackingMap] Failed to render dropoff pin: $e');
    }
    // Build pin+label bitmap variants for animated label reveal
    if (widget.pickupLabel.trim().isNotEmpty) {
      try {
        _pickupPinWithLabelBytes = await _renderGoldPinWithLabel(
          isPickup: true,
          label: widget.pickupLabel,
        );
      } catch (e) {
        debugPrint('[TrackingMap] Failed to render pickup pin with label: $e');
      }
    }
    if (widget.dropoffLabel.trim().isNotEmpty) {
      try {
        _dropoffPinWithLabelBytes = await _renderGoldPinWithLabel(
          isPickup: false,
          label: widget.dropoffLabel,
        );
      } catch (e) {
        debugPrint('[TrackingMap] Failed to render dropoff pin with label: $e');
      }
    }
    if (mounted) {
      _setState(() {});
      // Force annotation update now that bytes are ready
      _updateAnnotations();
    }
  }
  
  /// Load the car PNG and resize it to a reasonable map icon size.
  /// Stores PNG bytes (not RGBA) for use with PointAnnotation.
  Future<void> _loadCarIcon() async {
    final rideName = widget.rideName.toLowerCase();
    String carAsset;

    if (rideName.contains('vip') || rideName.contains('suv') || rideName.contains('suburban') || rideName.contains('luxury')) {
      carAsset = 'assets/images/car_suv.png';
    } else if (rideName.contains('sedan') || rideName.contains('premium') || rideName.contains('fusion')) {
      carAsset = 'assets/images/car_sedan.png';
    } else {
      carAsset = 'assets/images/car_economy.png';
    }
    debugPrint('[CarIcon] rideName="$rideName" → asset=$carAsset');

    try {
      final raw = await rootBundle.load(carAsset);
      _carPngBytes = await _resizePngForMap(raw.buffer.asUint8List(), maxDim: 240);
      debugPrint('[CarIcon] loaded ${_carPngBytes!.length} PNG bytes');
    } catch (e) {
      debugPrint('[CarIcon] FAILED to load $carAsset: $e');
      try {
        final raw = await rootBundle.load('assets/images/car_economy.png');
        _carPngBytes = await _resizePngForMap(raw.buffer.asUint8List(), maxDim: 240);
      } catch (e) {
        debugPrint('[CarIcon] Fallback car load failed: $e');
      }
    }
    if (mounted) {
      _setState(() {});
      // Try to create the car annotation now that we have the icon bytes.
      // If GPS hasn't arrived yet this is a no-op (guarded by _animPos check).
      _updateCarSmooth();
    }
  }

  /// Resize a PNG image and return PNG bytes (not RGBA).
  Future<Uint8List> _resizePngForMap(Uint8List pngBytes, {int maxDim = 160}) async {
    final codec = await ui.instantiateImageCodec(pngBytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;

    final scale = maxDim / math.max(img.width, img.height);
    final newW = (img.width * scale).round().clamp(1, maxDim);
    final newH = (img.height * scale).round().clamp(1, maxDim);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, newW.toDouble(), newH.toDouble()));
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(0, 0, newW.toDouble(), newH.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();
    final resized = await picture.toImage(newW, newH);
    // Return PNG bytes (PointAnnotation expects PNG, not raw RGBA)
    final byteData = await resized.toByteData(format: ui.ImageByteFormat.png);
    resized.dispose();
    picture.dispose();
    img.dispose();
    return byteData!.buffer.asUint8List();
  }

  /// Ease out cubic
  double _easeOutCubic(double t) {
    return 1.0 - math.pow(1.0 - t, 3);
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
    } catch (e) {
      debugPrint('[TrackingMap] Failed to reveal pickup label: $e');
    }
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
    } catch (e) {
      debugPrint('[TrackingMap] Failed to reveal dropoff label: $e');
    }
    _labelSpringAnimation(_dropoffAnnot!);
  }

  /// Spring scale animation for label reveal: 0.50 → 1.15 → 0.95 → 1.05 over 600ms.
  /// Runs on the shared [_animScheduler] (one vsync Ticker drives all pin
  /// animations together) instead of its own Timer.periodic.
  void _labelSpringAnimation(mapbox.PointAnnotation annot) {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    _labelAnimJob?.cancel();
    _labelAnimJob = _animScheduler.schedule(
      durationMs: 600,
      onTick: (t) {
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
      },
    );
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

    // Snap the polyline endpoints to the EXACT pickup/dropoff coordinates.
    // Mapbox Directions returns the route snapped to the nearest road, which
    // can be a few meters off the actual pin. Replacing the first/last
    // points guarantees the gold line visually touches both pins instead of
    // leaving a small gap at the start or end.
    if (tripRoute.length >= 2) {
      tripRoute[0] = widget.pickupLatLng;
      tripRoute[tripRoute.length - 1] = widget.dropoffLatLng;
    }

    // Always store trip route for later use when trip starts (pickup→dropoff)
    _tripRoutePts = tripRoute;

    if (_phase == _TrackPhase.arriving || _phase == _TrackPhase.arrived) {
      // Show trip route (pickup→dropoff) as dimmed background so the rider
      // can see the full trip plan while the driver is approaching/at pickup.
      // The approach route (driver→pickup) overlays as the gold line on first GPS.
      _pickupIdx = 0;
      _routePts = tripRoute; // keep trip route visible (drawn dimmed)
      _buildSegDist();
      _traveledM = 0;
      _tgtTraveledM = 0;
      _driverPos = const LatLng(0, 0); // Car hidden until first GPS
      _animPos = _driverPos;
      // Compute trip distance for display
      double acc = 0;
      for (int i = 0; i + 1 < tripRoute.length; i++) {
        acc += _hav(tripRoute[i], tripRoute[i + 1]);
      }
      _distanceMiles = acc;
      _etaMinutes = (acc / 0.4).ceil().clamp(1, 99);
    } else {
      // onTrip / nearDestination: use trip route (pickup→dropoff)
      _pickupIdx = 0;
      _routePts = tripRoute;
      _buildSegDist();
      _traveledM = 0;
      _tgtTraveledM = 0;
      // Car hidden until first real RTDB GPS — never show at pickup.
      // The car IS the driver; it must appear where the driver actually is.
      _driverPos = const LatLng(0, 0);
      _animPos = _driverPos;
      double acc = 0;
      for (int i = 0; i + 1 < _routePts.length; i++) {
        acc += _hav(_routePts[i], _routePts[i + 1]);
      }
      _distanceMiles = acc;
      _etaMinutes = (acc / 0.5).ceil().clamp(1, 99);
    }

    if (!mounted) return;
    _setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _fitAllPoints();
        Future.delayed(const Duration(milliseconds: 100), () {
          if (mounted) _fitRouteBounds();
        });
      }
    });
  }

  /// Fit route bounds applying precise padding for top and bottom cards.
  /// During onTrip: adaptive zoom — short routes show full remaining route,
  /// long routes show driver + enough ahead to see well (not zoomed out too far).
  /// During arrived: no-op — camera is locked via _fitArrivedBounds().
  void _fitRouteBounds() {
    if (_map == null || (_routePts.isEmpty && _tripRoutePts.isEmpty)) return;
    // Arrived phase uses _fitArrivedBounds() once, then camera stays still.
    if (_phase == _TrackPhase.arrived) return;
    // Skip if another camera animation is still running
    if (_cameraAnimating && DateTime.now().isBefore(_cameraAnimEnd)) return;

    // During onTrip: use chase camera (navigation-style) instead of bounds fit.
    // This keeps the driver at a fixed position on screen and the route
    // centered in the visible gap between cards — no zoom jitter.
    final isOnTrip = _phase == _TrackPhase.onTrip || _phase == _TrackPhase.nearDestination;
    if (isOnTrip && _animPos.latitude != 0) {
      _chaseCamera();
      return;
    }

    // Get actual card heights from GlobalKeys
    final topHeight = _topCardHeight;
    final bottomHeight = _bottomCardHeight;

    // Safe-area insets + card offsets from rider_tracking_screen build()
    final mq = MediaQuery.of(context).padding;
    final topPad = mq.top;   // safe area top
    final bottomPad = mq.bottom; // safe area bottom

    final pts = <LatLng>[];

    if (_phase == _TrackPhase.arriving) {
      // Arriving: show driver + pickup + dropoff so rider sees full trip plan
      pts.add(widget.pickupLatLng);
      pts.add(widget.dropoffLatLng);
      if (_animPos.latitude != 0 && _animPos.longitude != 0) pts.add(_animPos);
      if (_routePts.isNotEmpty) pts.addAll(_routePts);
      if (_tripRoutePts.isNotEmpty) pts.addAll(_tripRoutePts);
    } else {
      // Arrived / overview: show full route
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
    // Increased from +48 to +64 so the route is centered in the visible gap
    // between cards, not squeezed against the edges.
    // Top card: positioned at topPad + 10, height = topHeight
    // Bottom card: positioned at bottomPad + 16, height = bottomHeight
    _map?.cameraForCoordinatesPadding(
      [mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
       mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat))],
      mapbox.CameraOptions(bearing: 0, pitch: 0),
      mapbox.MbxEdgeInsets(
        top: topPad + 10 + topHeight + 64,
        bottom: bottomPad + 16 + bottomHeight + 64,
        left: 44,
        right: 44,
      ),
      null, null,
    ).then((cam) {
      if (!mounted || _map == null) return;
      final zoom = (cam.zoom ?? 14.0).clamp(11.0, 16.0);
      final clampedCam = mapbox.CameraOptions(
        center: cam.center,
        zoom: zoom,
        bearing: cam.bearing,
        pitch: cam.pitch,
        padding: cam.padding,
        anchor: cam.anchor,
      );
      // Lock camera during animation to prevent overlapping animations
      _cameraAnimating = true;
      // Longer flyTo (1200ms) for smoother transitions — matches 1500ms follow interval
      const dur = 1200;
      _cameraAnimEnd = DateTime.now().add(const Duration(milliseconds: dur - 50));
      _map!.flyTo(clampedCam, mapbox.MapAnimationOptions(duration: dur));
      Future.delayed(const Duration(milliseconds: dur), () {
        _cameraAnimating = false;
      });
    });
  }

  /// Navigation-style chase camera for onTrip phase.
  /// Keeps the driver at ~35% from the bottom of the visible map area
  /// (between the top and bottom cards) so the route ahead is always visible.
  /// Uses a fixed zoom to prevent zoom jitter from constant bounds re-calculation.
  void _chaseCamera() {
    if (_map == null) return;
    if (_animPos.latitude == 0 && _animPos.longitude == 0) return;
    if (_cameraAnimating && DateTime.now().isBefore(_cameraAnimEnd)) return;

    final mq = MediaQuery.of(context).padding;
    final topPad = mq.top;
    final bottomPad = mq.bottom;
    final topHeight = _topCardHeight;
    final bottomHeight = _bottomCardHeight;

    // Visible map area = screen minus cards and safe area
    final visibleTop = topPad + 10 + topHeight + 32;
    final visibleBottom = bottomPad + 16 + bottomHeight + 32;

    // Build bounds that include driver position AND destination
    // so the rider can see the full route ahead, not just the car.
    final pts = <mapbox.Point>[];
    pts.add(mapbox.Point(
      coordinates: mapbox.Position(_animPos.longitude, _animPos.latitude),
    ));
    pts.add(mapbox.Point(
      coordinates: mapbox.Position(widget.dropoffLatLng.longitude, widget.dropoffLatLng.latitude),
    ));
    // Also include pickup if we're near it (shows full trip context)
    if (_phase == _TrackPhase.onTrip && _tripJustStarted) {
      pts.add(mapbox.Point(
        coordinates: mapbox.Position(widget.pickupLatLng.longitude, widget.pickupLatLng.latitude),
      ));
    }

    _cameraAnimating = true;
    const dur = 1200;
    _cameraAnimEnd = DateTime.now().add(const Duration(milliseconds: dur - 50));

    // Use cameraForCoordinates to auto-fit zoom so full route is visible
    _map!.cameraForCoordinatesPadding(
      pts,
      mapbox.CameraOptions(bearing: 0, pitch: 0),
      mapbox.MbxEdgeInsets(
        top: visibleTop.toDouble(),
        bottom: visibleBottom.toDouble(),
        left: 28,
        right: 28,
      ),
      null,
      null,
    ).then((camera) {
      if (!mounted || _map == null) return;
      _map!.flyTo(
        mapbox.CameraOptions(
          center: camera.center,
          zoom: math.max(12.0, math.min(17.0, camera.zoom ?? 15.0)),
          bearing: 0,
          pitch: 0,
          padding: camera.padding,
        ),
        mapbox.MapAnimationOptions(duration: dur),
      );
    });

    Future.delayed(const Duration(milliseconds: dur), () {
      _cameraAnimating = false;
    });
  }

  void _throttleBoundsFit() {
    final now = DateTime.now();
    if (now.difference(_lastBoundsFit).inMilliseconds < 1500) return;
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
    // During arrived phase, camera is stable — no animations at all.
    if (_phase == _TrackPhase.arrived) return;

    final now = DateTime.now();
    // Chase mode: follow driver — throttle at 800ms to match camera follow timer.
    // 600ms animation finishes before next tick, preventing overlap jitter.
    if (_shouldFollowDriver && _animPos.latitude != 0) {
      if (now.difference(_lastBoundsFit).inMilliseconds < 800) return;
      _lastBoundsFit = now;
      _followDriver(_animPos, _animBearing);
      return;
    }
    if (now.difference(_lastBoundsFit).inMilliseconds < 2000) return;
    _lastBoundsFit = now;
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
              // Reset car annotation — old one was destroyed with previous map instance.
              _carAnnot = null;
              _carAnnotCreating = false;
              // Allow rider to pinch-zoom + pan + double-tap zoom so
              // they can inspect the route at their own pace.
              // Keep rotate / tilt disabled so the camera never breaks
              // the cinematic perspective the auto-fit chooses.
              // (Was fully locked — user reported they couldn't zoom
              // out to see the full route on long distances.)
              ctrl.gestures.updateSettings(mapbox.GesturesSettings(
                scrollEnabled: true,
                pinchToZoomEnabled: true,
                doubleTapToZoomInEnabled: true,
                doubleTouchToZoomOutEnabled: true,
                rotateEnabled: false,
                pitchEnabled: false,
                quickZoomEnabled: true,
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
              // Separate annotation manager for car icon (icon-anchor: center, on top)
              _carAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
              try {
                await ctrl.style.setStyleLayerProperty(_carAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
                await ctrl.style.setStyleLayerProperty(_carAnnotMgr!.id, 'icon-rotation-alignment', 'map');
                await ctrl.style.setStyleLayerProperty(_carAnnotMgr!.id, 'icon-allow-overlap', true);
                await ctrl.style.setStyleLayerProperty(_carAnnotMgr!.id, 'icon-ignore-placement', true);
                await ctrl.style.setStyleLayerProperty(_carAnnotMgr!.id, 'icon-anchor', 'center');
              } catch (_) {}
              _updateAnnotations();
              // Rider is identified by pickup pin — no location puck on tracking screen
            },
            onStyleLoadedListener: (_) async {
              if (_map != null) {
                await _applyDarkNavyGoldTheme(_map!);
                // Re-apply annotation manager layer properties after style reload
                if (_pointAnnotMgr != null) {
                  try {
                    await _map!.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
                    await _map!.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-rotation-alignment', 'viewport');
                    await _map!.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-allow-overlap', true);
                    await _map!.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-anchor', 'bottom');
                  } catch (_) {}
                }
                if (_carAnnotMgr != null) {
                  try {
                    await _map!.style.setStyleLayerProperty(_carAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
                    await _map!.style.setStyleLayerProperty(_carAnnotMgr!.id, 'icon-rotation-alignment', 'map');
                    await _map!.style.setStyleLayerProperty(_carAnnotMgr!.id, 'icon-allow-overlap', true);
                  } catch (_) {}
                }
              }
              // Car annotation is DESTROYED on style reload — Mapbox clears all
              // annotations when the style changes. We MUST null out _carAnnot
              // so _updateCarSmooth() recreates it instead of updating a ghost.
              _carAnnot = null;
              _carAnnotCreating = false;
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


  // ── Car update: uses PointAnnotation (same proven approach as pins) ──
  void _updateCarSmooth() {
    if (_map == null) {
      debugPrint('[CarIcon] SKIP: _map is null');
      return;
    }
    // Determine effective position: use _animPos if valid, fallback to _directTargetPos
    // during arriving phase before approach route loads. This ensures the car
    // appears immediately at the driver's real GPS position.
    LatLng effectivePos = _animPos;
    double effectiveBearing = _animBearing;

    if (_animPos.latitude == 0 && _animPos.longitude == 0) {
      // animPos not initialized yet — check if we have raw GPS fallback
      final directPos = _directTargetPos;
      if (directPos != null && directPos.latitude != 0 && directPos.longitude != 0) {
        effectivePos = directPos;
        effectiveBearing = _directTargetBearing ?? 0;
        // Seed animPos so next frame starts from real position (no teleport from 0,0)
        _animPos = effectivePos;
        _animBearing = effectiveBearing;
        _driverPos = effectivePos;
        _driverBearing = effectiveBearing;
      } else {
        debugPrint('[CarIcon] SKIP: no valid position yet — waiting for first driver GPS');
        return;
      }
    }

    if (_carPngBytes == null) {
      debugPrint('[CarIcon] SKIP: _carPngBytes is null');
      return;
    }

    final mgr = _carAnnotMgr;
    if (mgr == null) {
      debugPrint('[CarIcon] SKIP: _carAnnotMgr is null');
      return;
    }

    if (_carAnnot != null) {
      try {
        _carAnnot!.geometry = mapbox.Point(
          coordinates: mapbox.Position(effectivePos.longitude, effectivePos.latitude),
        );
        _carAnnot!.iconRotate = effectiveBearing;
        mgr.update(_carAnnot!).catchError((e) {
          debugPrint('[CarIcon] update failed: $e — will recreate next frame');
          _carAnnot = null;
          _carAnnotCreating = false;
        });
      } catch (e) {
        debugPrint('[CarIcon] update failed: $e — will recreate');
        _carAnnot = null;
        _carAnnotCreating = false;
      }
      return;
    }

    // First-time creation (async, guarded)
    if (_carAnnotCreating) return;
    _carAnnotCreating = true;
    _createCarAnnotation(effectivePos, effectiveBearing).then((annot) {
      _carAnnotCreating = false;
      if (annot == null) {
        debugPrint('[CarIcon] CREATE returned null — will retry next frame');
      } else {
        debugPrint('[CarIcon] CREATE success — car is now visible at (${effectivePos.latitude.toStringAsFixed(5)},${effectivePos.longitude.toStringAsFixed(5)})');
      }
    }).catchError((e) {
      debugPrint('[CarIcon] CREATE failed: $e — will retry next frame');
      _carAnnotCreating = false;
    });
  }

  /// Create the car PointAnnotation — called once, then updated in-place.
  /// Returns the created annotation so callers know if it succeeded.
  Future<mapbox.PointAnnotation?> _createCarAnnotation([LatLng? pos, double? bearing]) async {
    final mgr = _carAnnotMgr;
    if (mgr == null || _carPngBytes == null) return null;
    final effectivePos = pos ?? _animPos;
    final effectiveBearing = bearing ?? _animBearing;
    // Guard: never create at (0,0)
    if (effectivePos.latitude == 0 && effectivePos.longitude == 0) {
      debugPrint('[CarIcon] CREATE skipped: position is (0,0)');
      return null;
    }
    try {
      final annot = await mgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(
          coordinates: mapbox.Position(effectivePos.longitude, effectivePos.latitude),
        ),
        image: _carPngBytes!,
        iconSize: _kCarAnnotScale,
        iconAnchor: mapbox.IconAnchor.CENTER,
        // car_*.png assets all face UP (north) by default — no bearing offset needed.
        iconRotate: effectiveBearing,
        iconOffset: [0, 0],
      ));
      _carAnnot = annot;
      debugPrint('[CarIcon] PointAnnotation created at ${effectivePos.latitude},${effectivePos.longitude}');
      return annot;
    } catch (e) {
      debugPrint('[CarIcon] PointAnnotation creation FAILED: $e');
      return null;
    }
  }
  Future<void> _updateStaticAnnotationsOnce() async {
    if (_staticAnnotsDone) return;
    final pointMgr = _pointAnnotMgr;
    final polyMgr = _polylineAnnotMgr;
    if (pointMgr == null || polyMgr == null) return;
    if (_pickupPinBytes == null || _dropoffPinBytes == null) return;
    // During arriving/arrived: allow pins even when route is minimal (trip route is dimmed background)
    if (_routePts.length < 2 && _tripRoutePts.length < 2 && _phase != _TrackPhase.arriving && _phase != _TrackPhase.arrived) return;
    _staticAnnotsDone = true; // mark before await to prevent double-creation

    // ── Draw dimmed trip route (pickup→dropoff) — visible in all phases ──
    // During arriving/arrived, this shows the rider where the trip will go.
    final dimmedPts = _tripRoutePts.isNotEmpty ? _tripRoutePts : _routePts;
    if (dimmedPts.length >= 2) {
      final allCoords = dimmedPts.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
      try {
        _dimmedRouteAnnot ??= await polyMgr.create(mapbox.PolylineAnnotationOptions(
          geometry: mapbox.LineString(coordinates: allCoords),
          lineColor: const Color(0xFFFFD700).withValues(alpha: 0.20).toARGB32(),
          lineWidth: 5.0,
          lineJoin: mapbox.LineJoin.ROUND,
        ));
      } catch (e) {
        debugPrint('[TrackingMap] Failed to create dimmed route: $e');
      }
    }

    // Pickup pin — always visible
    if (_pickupPinBytes != null) {
      try {
        _pickupAnnot ??= await pointMgr.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(coordinates: mapbox.Position(widget.pickupLatLng.longitude, widget.pickupLatLng.latitude)),
          image: _pickupPinBytes!,
          iconSize: 0.80,
          iconAnchor: mapbox.IconAnchor.BOTTOM,
          iconOffset: [0, 0],
        ));
      } catch (e) {
        debugPrint('[TrackingMap] Failed to create pickup pin: $e');
      }
    } else {
      debugPrint('[TrackingMap] Pickup pin bytes not ready — will retry');
    }

    // Dropoff pin — always show so rider can see full trip plan
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
      // Animate pin pop: 0.01 → 0.90 → 0.72 → 0.80 over 500ms
      // (final 0.80 matches the smaller pickup-pin baseline)
      _animateDropoffPinPop();
    } catch (e) {
      debugPrint('[TrackingMap] Failed to create dropoff pin: $e');
    }
  }

  /// Pin pop spring animation for dropoff pin. Runs on the shared scheduler.
  void _animateDropoffPinPop() {
    if (_dropoffAnnot == null || _pointAnnotMgr == null) return;
    _dropoffPopJob?.cancel();
    _dropoffPopJob = _animScheduler.schedule(
      durationMs: 500,
      onTick: (t) {
        double scale;
        if (t < 0.4) {
          scale = 0.01 + (0.90 - 0.01) * (t / 0.4);
        } else if (t < 0.7) {
          scale = 0.90 + (0.72 - 0.90) * ((t - 0.4) / 0.3);
        } else {
          scale = 0.72 + (0.80 - 0.72) * ((t - 0.7) / 0.3);
        }
        try {
          _pointAnnotMgr!.update(_dropoffAnnot!..iconSize = scale);
        } catch (_) {}
      },
      onDone: () {
        // Reveal dropoff label after pin pop settles.
        Future.delayed(const Duration(milliseconds: 300), () {
          if (!mounted) return;
          _revealDropoffLabel();
        });
      },
    );
  }

  /// Called when the rider taps "Confirm" on the pickup overlay.
  /// Removes the dimmed preview and starts the illuminated animated route draw.
  void _restartRouteAnimation() {
    if (_routeDrawDone) return; // driver-starts-first path already drawing
    _removeDimmedRoute();
    if (_routePts.length < 2 && _tripRoutePts.isNotEmpty) {
      _routePts = _tripRoutePts;
      _buildSegDist();
    }
    _startAnimatedRouteDraw();
  }

  /// Pop-out animation for the pickup pin when driver picks up rider.
  /// Grows to 1.6x then shrinks to 0 and removes the annotation.
  void _popOutPickupPin() {
    if (_pickupPopping || _pickupAnnot == null || _pointAnnotMgr == null) return;
    _pickupPopping = true;
    _pickupPopOutJob?.cancel();
    _pickupPopOutJob = _animScheduler.schedule(
      durationMs: 600,
      onTick: (t) {
        double scale;
        if (t < 0.35) {
          scale = 0.80 + (1.25 - 0.80) * (t / 0.35); // grow
        } else {
          final st = (t - 0.35) / 0.65;
          scale = 1.25 * (1.0 - st * st); // ease-in shrink
        }
        try {
          _pointAnnotMgr!.update(_pickupAnnot!..iconSize = math.max(scale, 0.01));
        } catch (_) {}
      },
      onDone: () {
        _showPickupPin = false;
        try { _pointAnnotMgr!.delete(_pickupAnnot!); } catch (_) {}
        _pickupAnnot = null;
      },
    );
  }

  /// Animated route draw: progressively reveals the gold route line to dropoff
  Future<void> _startAnimatedRouteDraw() async {
    if (_routeDrawDone || _routePts.length < 2) return;
    _routeDrawDone = true;
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null) return;

    // Delete any existing route annotation so we draw fresh
    if (_remainingRouteAnnot != null) {
      try { await polyMgr.delete(_remainingRouteAnnot!); } catch (_) {}
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
        final fullGeom = mapbox.LineString(coordinates: allCoords);
        _remainingRouteAnnot!.geometry = fullGeom;
        polyMgr.update(_remainingRouteAnnot!).catchError((_) {});
        _routeDrawTicker?.stop();
      }
    })..start();
  }

  Future<void> _createRouteLayers(mapbox.PolylineAnnotationManager mgr, mapbox.LineString geom) async {
    // Single gold line — clean, no glow
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
    // When approach route is fetched (road-following), the main route polyline
    // IS the approach — no need for an extra straight line.
    if (_approachRouteFetched) return;

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
  
  /// Handle driver arrival: draw trip route, fit camera to pickup+dropoff, then STOP.
  /// Camera must be stable during arrived phase — no further animations.
  Future<void> _handleDriverArrived() async {
    if (_arrivedStateInitialized || _map == null) return;
    _arrivedStateInitialized = true;

    // ── Stop all camera movement ──
    _shouldFollowDriver = false;
    _cameraFollowTimer?.cancel();
    _cameraFollowTimer = null;

    // Remove approach route (driver→pickup) — driver is at pickup now.
    _routeFadeJob?.cancel();
    if (_approachAnnot != null && _polylineAnnotMgr != null) {
      try { await _polylineAnnotMgr!.delete(_approachAnnot!); } catch (_) {}
      _approachAnnot = null;
    }

    // Remove the old approach/remaining route annotation
    if (_remainingRouteAnnot != null && _polylineAnnotMgr != null) {
      try { await _polylineAnnotMgr!.delete(_remainingRouteAnnot!); } catch (_) {}
      _remainingRouteAnnot = null;
    }

    // Prepare trip route (pickup→dropoff) — the dimmed preview stays visible.
    // The animated illuminated draw fires later when the rider confirms pickup.
    if (_tripRoutePts.isNotEmpty) {
      _routePts = _tripRoutePts;
      _buildSegDist();
      _traveledM = 0;
      _tgtTraveledM = 0;
      _routeDrawDone = false;
      // Do NOT draw yet — deferred to _restartRouteAnimation() on rider confirm
    }

    // Ensure dropoff pin is visible
    if (_dropoffAnnot == null) {
      _dropoffPinAdded = false;
      _addDropoffPin();
    }

    // Fit camera to show pickup + dropoff ONCE, then stop — no more camera moves.
    Future.delayed(const Duration(milliseconds: 300), () {
      if (_map == null || !mounted) return;
      _fitArrivedBounds();
    });
  }

  /// Fit camera to pickup + dropoff only (arrived phase).
  /// Produces a stable view showing the full trip route without including
  /// the driver's jittery GPS position or approach route points.
  void _fitArrivedBounds() {
    if (_map == null) return;

    final mq = MediaQuery.of(context).padding;
    final topPad = mq.top;
    final bottomPad = mq.bottom;

    // Only include pickup, dropoff, and the trip route points between them.
    final pts = <LatLng>[
      widget.pickupLatLng,
      widget.dropoffLatLng,
    ];
    // Add trip route points so the camera fits the actual route path.
    if (_tripRoutePts.isNotEmpty) {
      pts.addAll(_tripRoutePts);
    }

    double minLat = pts[0].latitude, maxLat = pts[0].latitude;
    double minLng = pts[0].longitude, maxLng = pts[0].longitude;
    for (final p in pts) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }

    _map!.cameraForCoordinatesPadding(
      [mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
       mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat))],
      mapbox.CameraOptions(bearing: 0, pitch: 0),
      mapbox.MbxEdgeInsets(
        top: topPad + 10 + _topCardHeight + 48,
        bottom: bottomPad + 16 + _bottomCardHeight + 48,
        left: 44,
        right: 44,
      ),
      null, null,
    ).then((cam) {
      if (!mounted || _map == null) return;
      final zoom = (cam.zoom ?? 14.0).clamp(13.0, 16.0);
      final clampedCam = mapbox.CameraOptions(
        center: cam.center,
        zoom: zoom,
        bearing: cam.bearing,
        pitch: cam.pitch,
        padding: cam.padding,
        anchor: cam.anchor,
      );
      // Single flyTo — no further camera animations after this.
      // 800 → 1300 ms so the cinematic fit never snaps into place.
      _map!.flyTo(clampedCam, mapbox.MapAnimationOptions(duration: 1300));
    });
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
      // 650 → 1100 ms so the arrival recenter glides instead of snaps.
      await _map!.flyTo(cam, mapbox.MapAnimationOptions(duration: 1100));
    } catch (_) {
      await _map!.flyTo(
        mapbox.CameraOptions(center: point, zoom: 16.4, bearing: 0, pitch: 0),
        mapbox.MapAnimationOptions(duration: 1100),
      );
    }
  }

  /// Fade and remove the route polyline (for arrived state)
  Future<void> _fadeAndRemoveRoute() async {
    // This is handled by _handleDriverArrived
  }

  /// Animate camera to top-down follow centred on driver position.
  /// Called during the ride-start animation sequence (Phase 4).
  void _flyToDriverAt45() {
    if (_map == null) return;
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
        bearing: 0,
        pitch: 0,
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

    _routeFadeJob?.cancel();
    _routeFadeJob = _animScheduler.schedule(
      durationMs: 600,
      onTick: (t) {
        final opacity = 1.0 - t;
        if (_remainingRouteAnnot != null) {
          try {
            polyMgr.update(_remainingRouteAnnot!..lineOpacity = opacity);
          } catch (_) {}
        }
      },
      onDone: () async {
        _routeFadeJob = null;
        if (!mounted) return;
        if (_remainingRouteAnnot != null) {
          try {
            await polyMgr.delete(_remainingRouteAnnot!);
          } catch (_) {}
          _remainingRouteAnnot = null;
        }
        _routeDrawDone = false;
      },
    );
  }

  Future<void> _updateAnnotations() async {
    _updateCarSmooth();
    await _updateStaticAnnotationsOnce();
  }

  /// Enables the Mapbox native location puck — perfectly anchored to GPS,
  /// never drifts on zoom/pan, and updates in real time automatically.
  Future<void> _enableLocationPuck() async {
    final map = _map;
    if (map == null) return;
    try {
      // Rider is identified by the pickup pin — hide the blue GPS dot.
      await map.location.updateSettings(mapbox.LocationComponentSettings(
        enabled: false,
      ));
    } catch (_) {}
  }

  /// Start listening to rider's own GPS and keep the puck at current position.
  /// The puck follows GPS automatically via Mapbox internals, but we also
  /// manually update it so there is zero lag between OS location and map dot.
  void _startRiderLocationTracking() {
    // Blue puck disabled — rider is identified by the pickup pin.
    _enableLocationPuck();
  }
}
