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
    if (kIsWeb) {
      final web = _webMapCtrl;
      if (web != null) {
        web.clearMarkers();
        web.clearPolylines();
        web.clearCircles();
      }
      return;
    }
    // Clean up modular components first
    await _mapCar?.clear();
    await _mapRoute?.clear();
    await _mapAnnotations?.clear();

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
    // Load into modular component
    if (_mapAnnotations != null) {
      await _mapAnnotations!.loadPins(
        pickupLabel: widget.pickupLabel,
        dropoffLabel: widget.dropoffLabel,
      );
    }
    // Also load legacy inline pins for fallback
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

    // Also load into modular component
    if (_mapCar != null) {
      await _mapCar!.loadCarIcon(widget.rideName);
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
    if (_pickupLabelRevealed || _pickupPinWithLabelBytes == null) return;
    _pickupLabelRevealed = true;
    if (kIsWeb) {
      // Swap the marker icon for the pin+label bitmap (no spring anim on web).
      _webMapCtrl?.addMarker(
        'pickup',
        widget.pickupLatLng.longitude,
        widget.pickupLatLng.latitude,
        iconBytes: _pickupPinWithLabelBytes,
      );
      return;
    }
    // Use modular component if available
    if (_mapAnnotations != null) {
      _mapAnnotations!.revealPickupLabel();
      return;
    }
    // Legacy fallback
    if (_pickupAnnot == null) return;
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
    if (_dropoffLabelRevealed || _dropoffPinWithLabelBytes == null) return;
    _dropoffLabelRevealed = true;
    if (kIsWeb) {
      _webMapCtrl?.addMarker(
        'dropoff',
        widget.dropoffLatLng.longitude,
        widget.dropoffLatLng.latitude,
        iconBytes: _dropoffPinWithLabelBytes,
      );
      return;
    }
    // Use modular component if available
    if (_mapAnnotations != null) {
      _mapAnnotations!.revealDropoffLabel();
      return;
    }
    // Legacy fallback
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

  /// Road-route recovery: retries the pickup→dropoff fetch every 10 s (max
  /// 6) after a failed first ask. When it lands it becomes the stored trip
  /// route — and the ACTIVE line too if the rider is already aboard. Until
  /// then the map simply has no trip line, which is honest; a straight
  /// two-point line across the city is not.
  void _scheduleTripRouteRetry() {
    if (_tripRouteRetries >= 6) return;
    _tripRouteRetryTimer?.cancel();
    _tripRouteRetryTimer = Timer(const Duration(seconds: 10), () async {
      if (!mounted || _tripRoutePts.length >= 2) return;
      _tripRouteRetries++;
      try {
        final r = await DirectionsService(ApiKeys.webServices).getRoute(
          origin: widget.pickupLatLng,
          destination: widget.dropoffLatLng,
        );
        if (!mounted) return;
        final pts = r?.points;
        if (pts != null && pts.length >= 2) {
          final road = List<LatLng>.from(pts);
          road[0] = widget.pickupLatLng;
          road[road.length - 1] = widget.dropoffLatLng;
          _tripRoutePts = road;
          _mapRoute?.initRoute(
            routePoints: road,
            pickupLatLng: widget.pickupLatLng,
            dropoffLatLng: widget.dropoffLatLng,
          );
          if (_phase == _TrackPhase.onTrip ||
              _phase == _TrackPhase.nearDestination) {
            _routePts = List<LatLng>.from(road);
            _buildSegDist();
            _syncRouteToMap();
          }
          _updateAnnotations();
          debugPrint(
              '[RiderTracking] trip route recovered on retry $_tripRouteRetries');
          return;
        }
      } catch (e) {
        debugPrint('[RiderTracking] trip route retry failed: $e');
      }
      _scheduleTripRouteRetry();
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
      // NO straight-line stand-in (project rule — the user's "línea
      // recta" screenshot was exactly this two-point fallback becoming
      // the trip line). An empty route draws nothing — every consumer
      // guards on length >= 2 — and the retry below keeps asking the
      // router until the real road geometry lands.
      _scheduleTripRouteRetry();
    }

    // Snap the polyline endpoints to the EXACT pickup/dropoff coordinates.
    if (tripRoute.length >= 2) {
      tripRoute[0] = widget.pickupLatLng;
      tripRoute[tripRoute.length - 1] = widget.dropoffLatLng;
    }

    // Initialize modular route component
    if (_mapRoute != null) {
      _mapRoute!.initRoute(
        routePoints: tripRoute,
        pickupLatLng: widget.pickupLatLng,
        dropoffLatLng: widget.dropoffLatLng,
      );
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
    // The static-annotations pass is gated on route points; if it ran (and
    // bailed) before the route landed, nothing else re-triggers it and the
    // dropoff pin never appears. Idempotent — safe to nudge on every call.
    _updateAnnotations();
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
    if (kIsWeb) {
      _webFitRouteBounds();
      return;
    }
    if (_map == null || (_routePts.isEmpty && _tripRoutePts.isEmpty)) return;
    // Arrived phase uses _fitArrivedBounds() once, then camera stays still.
    if (_phase == _TrackPhase.arrived) return;

    // Once the rider is aboard, the chase ticker owns the camera outright.
    //
    // This used to stand down only while isNavChaseActive was true and
    // otherwise fall through to a driver+dropoff bounds fit — flat,
    // north-up, the car a speck against the whole remaining route. Every
    // gap in the chase leaked that view onto the screen: the frame before
    // the ticker seeds, the seconds after the rider pans, and worst of
    // all reopening the app mid-trip, where _shouldFollowDriver was still
    // false from the arrived phase so the ticker never took over at all —
    // that one lasted the entire ride.
    //
    // There is no bounds fit worth showing during a trip, so there is no
    // condition on this return.
    if (_phase == _TrackPhase.onTrip ||
        _phase == _TrackPhase.nearDestination) {
      return;
    }
    // Same reasoning for the approach phase, which now has its own
    // continuous framer. The first fit still runs — it lands before the
    // framer has seeded — and gives the opening shot the framer then
    // tightens from.
    if (_phase == _TrackPhase.arriving &&
        (_mapCamera?.isFollowFramingActive ?? false)) {
      return;
    }

    // Get actual card heights from GlobalKeys
    final topHeight = _topCardHeight;
    final bottomHeight = _bottomCardHeight;

    // Safe-area insets + card offsets from rider_tracking_screen build()
    final mq = MediaQuery.maybeOf(context)?.padding ?? EdgeInsets.zero;
    final topPad = mq.top;
    final bottomPad = mq.bottom;

    // Use modular camera component if available
    if (_mapCamera != null) {
      final pts = <LatLng>[];
      if (_phase == _TrackPhase.arriving) {
        // Opening shot of the approach = exactly what the framer will hold:
        // the car, the pickup and the road between them. It used to throw in
        // the dropoff and the whole trip route, which opened the phase zoomed
        // out over a destination miles away — the rider's first look at the
        // screen had the driver as a dot.
        pts.addAll(_approachFramePoints());
      } else {
        pts.add(widget.pickupLatLng);
        pts.add(widget.dropoffLatLng);
        if (_animPos.latitude != 0) pts.add(_animPos);
        pts.addAll(_routePts);
      }
      if (pts.isNotEmpty) {
        _mapCamera!.fitBounds(
          points: pts,
          topPadding: topPad + 10 + topHeight + 64,
          bottomPadding: bottomPad + 16 + bottomHeight + 64,
        );
      }
      return;
    }

    // Legacy fallback
    // Skip if another camera animation is still running
    if (_cameraAnimating && DateTime.now().isBefore(_cameraAnimEnd)) return;

    final pts = <LatLng>[];
    if (_phase == _TrackPhase.arriving) {
      pts.add(widget.pickupLatLng);
      pts.add(widget.dropoffLatLng);
      if (_animPos.latitude != 0 && _animPos.longitude != 0) pts.add(_animPos);
      if (_routePts.isNotEmpty) pts.addAll(_routePts);
      if (_tripRoutePts.isNotEmpty) pts.addAll(_tripRoutePts);
    } else {
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
      _cameraAnimating = true;
      // FIX: shorter animation (800ms) so the camera settles before the next
      // follow tick, preventing overlapping flyTo jumps.
      const dur = 800;
      _cameraAnimEnd = DateTime.now().add(const Duration(milliseconds: dur - 50));
      _map!.flyTo(clampedCam, mapbox.MapAnimationOptions(duration: dur));
      Future.delayed(const Duration(milliseconds: dur), () {
        _cameraAnimating = false;
      });
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
    // During the trip the chase ticker owns the camera and nothing
    // periodic gets to touch it. _fitRouteBounds() already bails on these
    // phases; this says so at the call site instead of two files away.
    if (_phase == _TrackPhase.onTrip ||
        _phase == _TrackPhase.nearDestination) {
      return;
    }

    final now = DateTime.now();
    // Chase mode: follow driver — throttle at 2000ms to match camera follow timer.
    // 800ms animation finishes well before next tick, preventing overlap jitter.
    if (_shouldFollowDriver && _animPos.latitude != 0) {
      if (now.difference(_lastBoundsFit).inMilliseconds < 2000) return;
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
    _userControllingCamera = false;
    _lastUserCameraInteraction = null;
    _setState(() {}); // drops the recenter button

    final isOnTrip =
        _phase == _TrackPhase.onTrip || _phase == _TrackPhase.nearDestination;
    if (isOnTrip || _phase == _TrackPhase.arriving) {
      // Drop the smoothing so the framer re-seeds from the live fit instead
      // of resuming from where the rider left the map.
      _mapCamera?.resetFollowFraming();
      // Then frame it here and now, rather than waiting for the framer to
      // seed on some later tick. The button says "show route"; it has to
      // answer with the route, immediately and in one move — resuming the
      // follow and letting it converge is what made it read as the camera
      // going back to chasing the car.
      final pts = isOnTrip ? _tripFramePoints() : _approachFramePoints();
      final mq = MediaQuery.maybeOf(context);
      if (_mapCamera != null && mq != null && pts.isNotEmpty) {
        _mapCamera!.fitBounds(
          points: pts,
          topPadding: mq.padding.top + 10 + _topCardHeight + 32,
          bottomPadding: mq.padding.bottom + 16 + _bottomCardHeight + 32,
        );
      }
      return;
    }
    _fitRouteBounds();
  }

  /// The rider dragged the map: hand them the camera and stop chasing.
  ///
  /// Driven by the map's scroll (gesture) callback, NOT by camera-change
  /// events. onCameraChangeListener fires for our own easeTo too, so it
  /// needed a "this one is mine" flag that was cleared by a 120 ms
  /// Future scheduled on every one of the 25 camera frames per second —
  /// and those clears regularly landed while an easeTo was still
  /// settling. The chase camera then declared the rider had grabbed the
  /// map and stopped following the car for the rest of the trip, with no
  /// gesture ever happening. A gesture callback cannot lie.
  void _onUserPannedMap() {
    if (!_userControllingCamera) {
      // Logged because the rider reports the camera handing itself over
      // without being touched. These are gesture callbacks, so they should
      // not fire for our own per-frame writes — if this line shows up in a
      // session where nobody touched the map, the listener is the liar and
      // the fix belongs here rather than in the framer.
      debugPrint('[Tracking] rider took the camera (pan/zoom gesture) — '
          'follow paused for ${_kResumeFollowAfterPanMs}ms');
      _userControllingCamera = true;
      _mapCamera?.stopNavigationChase();
      // Raises the recenter button. The flag flips twice a ride at most, so
      // the rebuild is free.
      _setState(() {});
    }
    _lastUserCameraInteraction = DateTime.now();
  }

  /// One vsync frame: advance the car, then move the camera after it.
  ///
  /// The car and the camera used to own a Ticker each. Both fired on
  /// vsync, so on a fast device they behaved identically — but they write
  /// to the Mapbox platform channel with different discipline. The car
  /// coalesces and re-sends the newest frame the instant its write lands
  /// ([TrackingMapCar._flushCarWrite]); the camera drops a frame when the
  /// channel is busy and waits for the next tick. On a saturated channel
  /// the car therefore won more slots than the camera, and a marker
  /// moving at twice the camera's rate visibly oscillates around its
  /// anchor: the map translates in coarser steps than the thing it is
  /// chasing.
  ///
  /// One ticker makes that impossible. Both writes are produced in the
  /// same frame from the same position, so whatever the channel does to
  /// one it does to the other. It also removes the frame of lag the
  /// camera used to read: _interpolate writes _animPos microseconds
  /// before _onCameraTick reads it, not one vsync earlier.
  ///
  /// Order matters — car first, camera second. The reverse would frame
  /// the position the car is about to leave.
  void _onAnimationFrame(Duration elapsed) {
    _interpolate(elapsed);
    _onCameraTick(elapsed);
    // Repaint the Flutter-painted car with this frame. See _carFrame.
    if (mounted) _carFrame.value++;
  }

  /// Make sure the shared animation frame is running.
  ///
  /// The camera does not own a Ticker any more — it rides the
  /// interpolation one (see [_onAnimationFrame]), so "start the camera"
  /// means "make sure that ticker is awake". It only ever idles itself
  /// once the trip is completed, which is also the one phase the camera
  /// must not move in.
  void _startCameraTicker() {
    if (!mounted) return;
    final t = _interpTicker;
    if (t != null && !t.isActive) t.start();
  }

  /// Whether the camera is allowed to track anything this frame.
  ///
  /// Derived from the phase, not from a flag someone has to remember to
  /// reset. _shouldFollowDriver is switched off when the driver reaches
  /// the pickup — deliberately, the camera freezes there — and only
  /// _transitionToOnTrip ever switched it back on. Reopening the app
  /// mid-trip restores straight into the onTrip phase without passing
  /// through that method, so the flag stayed false, this ticker returned
  /// on its first line, and the chase never started for the rest of the
  /// ride. A phase cannot fall out of sync with itself.
  bool get _cameraChaseAllowed =>
      _phase != _TrackPhase.arrived && _phase != _TrackPhase.completed;

  /// Ticker callback: drive the Uber-style chase camera.
  void _onCameraTick(Duration elapsed) {
    if (kIsWeb) {
      _webCameraTick();
      return;
    }
    if (!mounted || _map == null || _mapCamera == null) return;

    // Before anything that can return early. The annotation is only allowed
    // to be invisible while the overlay is actually drawing, and this is the
    // one line that decides it — see _chaseCarAnchor.
    unawaited(_mapCar?.setHidden(_chaseCarAnchor != null) ?? Future.value());

    // Auto-resume: hand the camera back after the rider stops panning.
    // _lastUserCameraInteraction was being written and never read, so a
    // single pan parked the camera permanently — the car drove off screen
    // and never came back for the rest of the ride.
    if (_userControllingCamera) {
      final last = _lastUserCameraInteraction;
      if (last == null ||
          DateTime.now().difference(last).inMilliseconds >
              _kResumeFollowAfterPanMs) {
        _userControllingCamera = false;
        _lastUserCameraInteraction = null;
        // The full-route frame comes back too (2026-09-13): resume used to
        // leave the camera wherever the rider abandoned it, and since the
        // route signature hadn't changed the fit never re-ran — the dropoff
        // pin could sit off-screen for the rest of the trip.
        _needsTripReframe = true;
        // Re-seed from the live fit: the framer's smoothed centre/zoom are
        // from before the rider moved the map, so writing them straight out
        // would snap the view instead of gliding back.
        _mapCamera?.resetFollowFraming();
        _setState(() {}); // drops the recenter button
      } else {
        return;
      }
    }
    if (!_cameraChaseAllowed) return;
    if (_animPos.latitude == 0 && _animPos.longitude == 0) return;

    // No throttle: the camera runs at the ticker's own rate, matching the
    // car marker frame for frame. A 25 fps camera under a 60 fps marker
    // makes the car visibly oscillate around its anchor, because the map
    // translates in coarser steps than the thing it is following.
    // updateChaseFrame drops frames itself when the channel is busy.

    // maybeOf, not of: this runs from a ticker, and a ticker frame can land
    // on a deactivated element while `mounted` is still true. See rule 26.
    final mq = MediaQuery.maybeOf(context);
    if (mq == null) return;
    final topPad = mq.padding.top;
    final bottomPad = mq.padding.bottom;
    final screenSize = mq.size;

    // ── Both halves of the ride are framed the same way ──
    // The rider is reading a map, not driving one: whatever is still ahead —
    // the car, the pin it is going to, and the road between them — stays
    // fully on screen.
    final isOnTrip =
        _phase == _TrackPhase.onTrip || _phase == _TrackPhase.nearDestination;
    if (_phase != _TrackPhase.arriving && !isOnTrip) return;

    if (isOnTrip) {
      if (_mapCamera!.isNavChaseActive) {
        // Leaves the car marker to Mapbox again — _chaseCarAnchor goes null,
        // so the Flutter-painted chase car stops and the annotation shows.
        _mapCamera!.stopNavigationChase();
      }
      // ONE stable frame for the whole ride (user spec 2026-08-09): fit the
      // full trip route BETWEEN the top card and the bottom sheet and HOLD
      // it — a moderate zoom-out, no auto-recenter. The per-frame
      // updateFollowFrame recentered continuously, and its custom span math
      // let the route slide behind the cards; fitBounds uses the native
      // padding, so nothing hides. Re-fit ONLY when the frame content
      // changes (late route seed, restore, a real reroute of the trip
      // polyline) — never because the car moved.
      final sig = _tripFitSignature();
      // _needsTripReframe forces the fit without a content change: the
      // rider panned (auto-resume above) or a reroute replaced the drawn leg
      // — the full route and the dropoff pin always come back on screen.
      if (sig != 0 && (sig != _lastTripFitSig || _needsTripReframe)) {
        _lastTripFitSig = sig;
        _needsTripReframe = false;
        unawaited(_mapCamera!.fitBounds(
          points: _tripFramePoints(),
          topPadding: topPad + 10 + _topCardHeight + 32,
          bottomPadding: bottomPad + 16 + _bottomCardHeight + 32,
        ));
      }
      return;
    }

    // Approach phase keeps the per-frame follow: the driver is moving
    // toward the rider, so the frame has to track that.
    if (_framedPhaseKind != 0) {
      _framedPhaseKind = 0;
      _mapCamera!.resetFollowFraming();
    }

    _mapCamera!.updateFollowFrame(
      points: _approachFramePoints(),
      screenSize: screenSize,
      topPadding: topPad + 10 + _topCardHeight + 32,
      bottomPadding: bottomPad + 16 + _bottomCardHeight + 32,
    );
  }

  /// Identity of the trip frame's CONTENT, not of the camera: the route
  /// polyline that must stay visible. The car (_animPos) is deliberately
  /// NOT part of this — the fit includes it, but its movement must never
  /// retrigger the fit (that was the auto-recenter the rider killed).
  int _tripFitSignature() {
    final pts = _tripRoutePts.length >= 2 ? _tripRoutePts : _routePts;
    if (pts.length < 2) return 0;
    return Object.hash(
      pts.length,
      pts.first.latitude, pts.first.longitude,
      pts.last.latitude, pts.last.longitude,
    );
  }

  /// Driver → pickup: the car, the pickup pin, and the approach road.
  ///
  /// The route is only added when it actually ends at the pickup. During
  /// this phase `_routePts` briefly carries the pickup→dropoff route on some
  /// paths (restore, preloaded trip route), and framing that here would zoom
  /// out to the whole trip while the rider is still waiting on the curb.
  List<LatLng> _approachFramePoints() {
    final pts = <LatLng>[widget.pickupLatLng];
    // (0,0) is "no fix yet", not the Gulf of Guinea — framing it would zoom
    // out to half the planet.
    if (_animPos.latitude != 0 || _animPos.longitude != 0) pts.add(_animPos);
    if (_routePts.isNotEmpty &&
        _hav(_routePts.last, widget.pickupLatLng) * 1609.34 < 250) {
      pts.addAll(_routePts);
    }
    return pts;
  }

  /// Driver → dropoff: the car, the destination, and the road still ahead.
  List<LatLng> _tripFramePoints() {
    final pts = <LatLng>[widget.dropoffLatLng];
    if (_animPos.latitude != 0 || _animPos.longitude != 0) pts.add(_animPos);
    // The WHOLE trip, always (user spec 2026-08-08): the rider's map shows
    // the complete route — pickup to dropoff — for the entire ride. Framing
    // only what is left zoomed the camera into a slice of the road and cut
    // the trip off both edges of the screen on long routes. `_tripRoutePts`
    // is the immutable full-trip polyline — traffic refreshes and off-route
    // reroutes only replace `_routePts` (the remaining car→dropoff leg used
    // for drawing/ETA), so framing must read the stored trip route. `_routePts`
    // stays as the fallback for paths where the trip route never seeded.
    if (_tripRoutePts.length >= 2) {
      pts.addAll(_tripRoutePts);
      // Cover the CURRENT drawn leg too (2026-09-13): an off-route reroute
      // splices new streets outside the original trip geometry, and a frame
      // that only holds the original lets the rerouted line — and with it
      // the dropoff pin — leave the screen. Erasing shrinks this list into
      // the trip bbox, so it costs nothing on-route.
      pts.addAll(_routePts);
    } else {
      pts.addAll(_routePts);
    }
    return pts;
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
  /// The car, painted by Flutter while the chase camera owns the screen.
  ///
  /// Same move as the driver's own arrow: a Mapbox annotation can only
  /// advance as fast as the platform channel drains, and on a phone
  /// rendering this map that is ten or fifteen times a second against a
  /// display doing sixty. During the chase the car does not travel across
  /// the screen at all — it is pinned to the anchor while the world slides
  /// underneath — so there is nothing to send. Painting it here also hands
  /// the whole channel to the camera, which is the thing that actually has
  /// to move.
  ///
  /// Laid down onto the road, not stood up on the glass: the annotation
  /// underneath uses `icon-pitch-alignment: map`, so a flat billboard here
  /// would be a different car. The X rotation by the camera's own pitch is
  /// what puts it back on the tarmac.
  /// Where the Flutter-painted car goes, or null if it is not drawing.
  ///
  /// The one place that decides. The overlay reads it to know whether to
  /// paint, and the annotation underneath reads it to know whether to hide
  /// — so the two can never disagree, and there can never be a moment with
  /// no car at all.
  ///
  /// There was one. The hide was written next to the chase-frame call, and
  /// the tick returns before that as soon as the rider drags the map. So a
  /// drag left the annotation invisible from the frame before and the
  /// overlay switched off by the drag: the car vanished for the whole eight
  /// seconds until the camera came back. Two places deciding one thing.
  Offset? get _chaseCarAnchor {
    final cam = _mapCamera;
    final car = _mapCar;
    if (cam == null || car == null) return null;
    if (!mounted) return null;
    if (_phase != _TrackPhase.onTrip && _phase != _TrackPhase.nearDestination) {
      return null;
    }
    if (_userControllingCamera) return null;
    if (car.carBytes == null) return null;
    final mq = MediaQuery.maybeOf(context);
    if (mq == null) return null;
    return cam.chaseAnchor(
      mq.size,
      mq.padding.top + 10 + _topCardHeight + 32,
      mq.padding.bottom + 16 + _bottomCardHeight + 32,
    );
  }

  Widget _buildChaseCarOverlay() {
    final cam = _mapCamera;
    final car = _mapCar;
    final anchor = _chaseCarAnchor;
    if (cam == null || car == null || anchor == null) {
      return const SizedBox.shrink();
    }
    final bytes = car.carBytes;
    if (bytes == null) return const SizedBox.shrink();

    // The map is already turned to the car's heading, so what is left is
    // whatever the smoothing has not caught up on yet — usually near zero,
    // which is exactly why the car sits still while the world turns.
    final relBearing = (_animBearing - cam.navBearing) * math.pi / 180.0;
    final pitchRad = cam.navPitch * math.pi / 180.0;
    final size = 160.0 * car.carScale;

    return Positioned(
      left: anchor.dx - size / 2,
      top: anchor.dy - size / 2,
      width: size,
      height: size,
      child: IgnorePointer(
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            // A touch of perspective, then lie the image down by the same
            // angle the camera is leaning. Without the perspective entry the
            // X rotation is an orthographic squash and the car reads as
            // flattened rather than as receding.
            ..setEntry(3, 2, 0.0015)
            ..rotateX(pitchRad)
            ..rotateZ(relBearing),
          child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
        ),
      ),
    );
  }

  Widget _buildFullScreenMap() {
    return Stack(
      children: [
        // Held back until this screen owns the one live Mapbox surface —
        // the booking screen underneath still has its map up until then.
        if (!_mapMounted)
          const Positioned.fill(
            child: ColoredBox(color: Color(0xFF07080D)),
          )
        else if (kIsWeb)
          // Mapbox GL JS in the browser — the native MapWidget below does
          // not exist on web and crashes the whole screen. Same pattern as
          // ride_request_screen: WebMapView + WebMapController helpers.
          WebMapView(
            key: const ValueKey('rider-map-web'),
            initialLng: widget.pickupLatLng.longitude,
            initialLat: widget.pickupLatLng.latitude,
            initialZoom: 14,
            styleUri: MapboxConfig.styleDark,
            onControllerCreated: (c) {
              _webMapCtrl = c;
              // The same navy/gold the native map gets in
              // _applyDarkNavyGoldTheme — raw dark-v11 is grey, not ours.
              c.applyNavyGoldTheme();
              c.onCameraMove = (_, __, ___) {
                if (!mounted) return;
                // Our own fits/follows land inside the programmatic window —
                // anything outside it is the rider's hand.
                if (DateTime.now().isAfter(_webAutoCameraUntil)) {
                  _onUserPannedMap();
                }
              };
              c.onReady = () {
                if (!mounted) return;
                _setState(() {
                  _mapLoadError = false;
                  _mapErrorMessage = '';
                });
                // Static creation is guarded + idempotent; nudge it in case
                // pins/route were ready before the GL style finished loading.
                _updateStaticAnnotationsOnce();
                _fitRouteBounds();
              };
            },
          )
        else
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
              // Cache controller for reuse across rider screens
              MapControllerCache.instance.cache(ctrl);
              // Reset car annotation — old one was destroyed with previous map instance.
              _carAnnot = null;
              _carAnnotCreating = false;
              // Allow rider to pan, zoom, rotate and tilt so they can
              // inspect the route. The navigation chase camera pauses
              // automatically when the user touches the map.
              ctrl.gestures.updateSettings(mapbox.GesturesSettings(
                scrollEnabled: true,
                pinchToZoomEnabled: true,
                doubleTapToZoomInEnabled: true,
                doubleTouchToZoomOutEnabled: true,
                rotateEnabled: true,
                pitchEnabled: true,
                quickZoomEnabled: true,
              ));
              ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
              ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
              ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
              ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));
              // Every await here is a chance for the screen to go away —
              // the rider pops back, the trip completes and pushes rating,
              // the OS destroys the surface on background. Continuing past
              // that point calls into a freed native map and takes the app
              // down with no Dart error. Same guard as the driver's online
              // screen; this is the rider's copy of that crash.
              final poly = await ctrl.annotations.createPolylineAnnotationManager(
                below: 'road-label',
              );
              if (!mounted) return;
              _polylineAnnotMgr = poly;

              final point = await ctrl.annotations.createPointAnnotationManager();
              if (!mounted) return;
              _pointAnnotMgr = point;
              try {
                await ctrl.style.setStyleLayerProperty(point.id, 'icon-pitch-alignment', 'viewport');
                await ctrl.style.setStyleLayerProperty(point.id, 'icon-rotation-alignment', 'viewport');
                await ctrl.style.setStyleLayerProperty(point.id, 'icon-allow-overlap', true);
                await ctrl.style.setStyleLayerProperty(point.id, 'icon-ignore-placement', true);
                await ctrl.style.setStyleLayerProperty(point.id, 'icon-anchor', 'bottom');
              } catch (_) {}
              if (!mounted) return;
              // Separate annotation manager for car icon (icon-anchor: center, on top)
              final car = await ctrl.annotations.createPointAnnotationManager();
              if (!mounted) return;
              _carAnnotMgr = car;

              // Initialize new modular map components (AFTER managers are created)
              _mapAnnotations = TrackingMapAnnotations(map: ctrl, pointAnnotMgr: _pointAnnotMgr);
              _mapRoute = TrackingMapRoute(map: ctrl, polylineAnnotMgr: _polylineAnnotMgr);
              _mapCamera = TrackingMapCamera(ctrl);
              _mapCar = TrackingMapCar(map: ctrl, carAnnotMgr: _carAnnotMgr);
              // Load the car icon the moment the component exists. It used
              // to be a 500 ms timer from initState that simply skipped
              // when the map was not up yet — and then never retried.
              unawaited(_mapCar!.loadCarIcon(widget.rideName));
              // Load data into modular components
              unawaited(_mapAnnotations!.loadPins(
                pickupLabel: widget.pickupLabel,
                dropoffLabel: widget.dropoffLabel,
              ).then((_) {
                // Pin bytes ready — the static pass below ran before they
                // finished rendering and bailed on the pinsReady gate.
                if (mounted) _updateAnnotations();
              }));
              _mapCar!.loadCarIcon(widget.rideName);
              try {
                // 'map', not 'viewport': the car lies FLAT ON THE ROAD and
                // tilts with it. On 'viewport' it billboards — stays square
                // to the screen however far the rider tilts the map — so a
                // top-down car render ends up standing upright on a slanted
                // street like a sticker on the glass. Pins keep 'viewport'
                // (a pin should stand up); a vehicle should not.
                await ctrl.style.setStyleLayerProperty(_carAnnotMgr!.id, 'icon-pitch-alignment', 'map');
                await ctrl.style.setStyleLayerProperty(_carAnnotMgr!.id, 'icon-rotation-alignment', 'map');
                await ctrl.style.setStyleLayerProperty(_carAnnotMgr!.id, 'icon-allow-overlap', true);
                await ctrl.style.setStyleLayerProperty(_carAnnotMgr!.id, 'icon-ignore-placement', true);
                await ctrl.style.setStyleLayerProperty(_carAnnotMgr!.id, 'icon-anchor', 'center');
              } catch (_) {}
              _updateAnnotations();
              // Rider is identified by pickup pin — no location puck on tracking screen

              // FIX: Immediately fit bounds once map is ready so the rider sees
              // the full route (pickup + dropoff + driver) instead of a static
              // zoom-14 view centered on pickup. This is critical for the smooth
              // transition from SearchingDriverScreen → RiderTrackingScreen.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _map != null) {
                  // Small delay to ensure annotation managers are fully initialized
                  Future.delayed(const Duration(milliseconds: 150), () {
                    if (mounted && _map != null) _fitRouteBounds();
                  });
                }
              });
            },
            // Gesture callbacks, not onCameraChangeListener: the latter also
            // fires for our own camera writes. See _onUserPannedMap.
            //
            // BOTH of these. A pinch is not a scroll, so with only the
            // scroll listener wired the rider's zoom was never registered as
            // a gesture — the very next framer tick overwrote it with its
            // own zoom, and pinching the tracking map did nothing at all.
            onScrollListener: (_) => _onUserPannedMap(),
            onZoomListener: (_) => _onUserPannedMap(),
            onMapLoadErrorListener: (err) {
              debugPrint('[TrackingMap] Map load error: ${err.message} (type: ${err.type})');
              _setState(() {
                _mapLoadError = true;
                _mapErrorMessage = err.message;
              });
            },
            onStyleLoadedListener: (_) async {
              if (_map == null) return;
              _setState(() {
                _mapLoadError = false;
                _mapErrorMessage = '';
              });
              await _applyDarkNavyGoldTheme(_map!);

              // Annotation managers are DESTROYED on style reload — Mapbox
              // clears all annotations AND managers when the style changes.
              // We MUST null them out AND recreate them, then redraw everything.
              _carAnnot = null;
              _carAnnotCreating = false;
              _carAnnotMgr = null;
              _pointAnnotMgr = null;
              _polylineAnnotMgr = null;
              _pickupAnnot = null;
              _dropoffAnnot = null;
              _remainingRouteAnnot = null;
              _dimmedRouteAnnot = null;
              _approachAnnot = null;
              // Reset modular components
              _mapCar?.reset();
              _mapAnnotations?.reset();
              _mapRoute?.reset();
              // Reset flags so static annotations (pins + dimmed route) are recreated
              _staticAnnotsDone = false;
              _dropoffPinAdded = false;

              // Recreate annotation managers
              try {
                _polylineAnnotMgr = await _map!.annotations.createPolylineAnnotationManager(
                  below: 'road-label',
                );
                _pointAnnotMgr = await _map!.annotations.createPointAnnotationManager();
                await _map!.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
                await _map!.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-rotation-alignment', 'viewport');
                await _map!.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-allow-overlap', true);
                await _map!.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-ignore-placement', true);
                await _map!.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-anchor', 'bottom');
              } catch (_) {}
              try {
                _carAnnotMgr = await _map!.annotations.createPointAnnotationManager();
                // Same as above — this is the style-reload path, and it has
                // to agree with it or the car flips behaviour on a restyle.
                await _map!.style.setStyleLayerProperty(_carAnnotMgr!.id, 'icon-pitch-alignment', 'map');
                await _map!.style.setStyleLayerProperty(_carAnnotMgr!.id, 'icon-rotation-alignment', 'map');
                await _map!.style.setStyleLayerProperty(_carAnnotMgr!.id, 'icon-allow-overlap', true);
                await _map!.style.setStyleLayerProperty(_carAnnotMgr!.id, 'icon-ignore-placement', true);
                await _map!.style.setStyleLayerProperty(_carAnnotMgr!.id, 'icon-anchor', 'center');
              } catch (_) {}

              // Re-initialize modular components with new managers
              _mapAnnotations?.setAnnotManager(_pointAnnotMgr);
              _mapRoute?.setAnnotManager(_polylineAnnotMgr);
              _mapCar?.setAnnotManager(_carAnnotMgr);

              // Redraw all annotations (pins, route, car)
              _updateAnnotations();

              // Redraw the gold route line.
              //
              // This branch runs when iOS destroys and recreates the map —
              // which is exactly what happens when the rider leaves the app
              // and comes back. The native line dies with the old map and
              // _remainingRouteAnnot is nulled above, but `_routeDrawDone`
              // stayed true from the first draw, so _startAnimatedRouteDraw
              // returned at its guard and NOTHING ever drew the line again.
              // _updateAnnotations only covers pins and the car.
              // The rider came back from the home screen to a map with no
              // route on it for the rest of the trip.
              if (_routePts.length >= 2 && _phase != _TrackPhase.completed) {
                _routeDrawDone = false;
                _syncRouteToMap();
                _startAnimatedRouteDraw();
              }

              // After style reload, re-fit bounds to ensure the route is visible
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _map != null) {
                  Future.delayed(const Duration(milliseconds: 200), () {
                    if (mounted && _map != null) _fitRouteBounds();
                  });
                }
              });
            },
          ),
        ),
        // The car, painted on top while the chase owns the camera. Rebuilt
        // by _carFrame on every animation frame, not by the screen's own
        // 3 fps setState.
        ListenableBuilder(
          listenable: _carFrame,
          builder: (_, __) => _buildChaseCarOverlay(),
        ),
        // Show error overlay when map fails to load
        if (_mapLoadError)
          Container(
            color: Colors.black,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.map_outlined, color: Colors.white38, size: 48),
                  const SizedBox(height: 16),
                  const Text(
                    'Map unavailable',
                    style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _mapErrorMessage.isNotEmpty ? _mapErrorMessage : 'Check your connection and try again',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13),
                  ),
                ],
              ),
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


  // ── Car update: delegates to TrackingMapCar ──
  void _updateCarSmooth() {
    if (kIsWeb) {
      _webUpdateCarMarker();
      return;
    }
    if (_map == null) return;

    // Determine effective position: use _animPos if valid, fallback to _directTargetPos
    LatLng effectivePos = _animPos;
    double effectiveBearing = _animBearing;

    if (_animPos.latitude == 0 && _animPos.longitude == 0) {
      final directPos = _directTargetPos;
      if (directPos != null && directPos.latitude != 0 && directPos.longitude != 0) {
        effectivePos = directPos;
        effectiveBearing = _directTargetBearing ?? 0;
        _animPos = effectivePos;
        _animBearing = effectiveBearing;
        _driverPos = effectivePos;
        _driverBearing = effectiveBearing;
      } else {
        return; // No valid position yet
      }
    }

    // Live path: TrackingMapCar runs a latest-wins pipeline, so it is fed
    // every animation frame and paces itself against the platform channel.
    // No fixed throttle here — that was a hard 30 fps ceiling on the one
    // thing the rider watches for the whole trip.
    if (_mapCar != null) {
      _mapCar!.updatePosition(
        effectivePos,
        bearing: effectiveBearing,
        // Lets it load its own icon if the startup race lost.
        rideName: widget.rideName,
      );
      return;
    }

    // ── Legacy path (modular component not ready yet) ──
    // No backpressure here, so it keeps the old fixed throttle.
    final now = DateTime.now();
    if (now.difference(_lastCarUpdate).inMilliseconds <
        _RiderTrackingScreenState._minCarUpdateMs) {
      return;
    }
    _lastCarUpdate = now;

    if (_carPngBytes == null) return;
    final mgr = _carAnnotMgr;
    if (mgr == null) return;

    // UPDATE existing annotation
    if (_carAnnot != null) {
      try {
        _carAnnot!.geometry = mapbox.Point(
          coordinates: mapbox.Position(effectivePos.longitude, effectivePos.latitude),
        );
        _carAnnot!.iconRotate = effectiveBearing;
        mgr.update(_carAnnot!).catchError((e) {
          // Project rule 17: a failed update may have left the OLD marker
          // alive on the map. Nulling only the handle made the next tick
          // create a SECOND car next to it (the rider's two-cars
          // screenshot). Fire-and-forget the delete before letting a new
          // create happen — same recipe as the home mini map dot.
          final stale = _carAnnot;
          _carAnnot = null;
          _carAnnotCreating = false;
          if (stale != null) {
            mgr.delete(stale).catchError((_) {});
          }
        });
      } catch (e) {
        final stale = _carAnnot;
        _carAnnot = null;
        _carAnnotCreating = false;
        if (stale != null) {
          try { mgr.delete(stale).catchError((_) {}); } catch (_) {}
        }
      }
      return;
    }

    // CREATE new annotation — guarded against race conditions
    if (_carAnnotCreating) return;
    _carAnnotCreating = true;
    _createCarAnnotation(effectivePos, effectiveBearing).then((annot) {
      _carAnnotCreating = false;
    }).catchError((e) {
      _carAnnotCreating = false;
    });
  }

  /// Create the car PointAnnotation — SINGLETON, never creates duplicates.
  /// Uses a Future lock to prevent race conditions when called concurrently.
  Future<mapbox.PointAnnotation?> _createCarAnnotation([LatLng? pos, double? bearing]) async {
    // If already have an annotation, don't create another
    if (_carAnnot != null) return _carAnnot;
    
    // If creation is in progress, wait for it instead of starting a second one
    if (_carAnnotCreating) {
      // Wait for the in-flight creation to complete (max 2 seconds)
      for (int i = 0; i < 20; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (_carAnnot != null) return _carAnnot;
        if (!_carAnnotCreating) break;
      }
      // After waiting, if we still don't have an annotation and no one is creating, proceed
      if (_carAnnot != null) return _carAnnot;
      if (_carAnnotCreating) return null; // Still creating, someone else won
    }
    
    _carAnnotCreating = true;
    
    final mgr = _carAnnotMgr;
    if (mgr == null || _carPngBytes == null) {
      _carAnnotCreating = false;
      return null;
    }
    
    final effectivePos = pos ?? _animPos;
    final effectiveBearing = bearing ?? _animBearing;
    
    // Guard: never create at (0,0) or with NaN
    if (effectivePos.latitude == 0 && effectivePos.longitude == 0) {
      _carAnnotCreating = false;
      return null;
    }
    if (!isValidLatLng(effectivePos.latitude, effectivePos.longitude)) {
      debugPrint('[TrackingMap] Skipping car annotation — invalid coords: $effectivePos');
      _carAnnotCreating = false;
      return null;
    }
    
    // Double-check after acquiring lock
    if (_carAnnot != null) {
      _carAnnotCreating = false;
      return _carAnnot;
    }
    
    try {
      // Project rule 17: the car manager owns exactly ONE annotation, so a
      // deleteAll before create is a free dedup — it clears any zombie the
      // failed-update path could not confirm dead, instead of drawing the
      // new car next to it.
      try { await mgr.deleteAll(); } catch (_) {}
      // Create car with size 0 for pop-in animation
      final annot = await mgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(
          coordinates: mapbox.Position(effectivePos.longitude, effectivePos.latitude),
        ),
        image: _carPngBytes!,
        iconSize: _carPopDone ? _kCarAnnotScale : 0.01,
        iconAnchor: mapbox.IconAnchor.CENTER,
        iconRotate: effectiveBearing,
        iconOffset: [0, 0],
      ));
      _carAnnot = annot;
      
      // Pop-in animation on first creation
      if (!_carPopDone) {
        _carPopDone = true;
        _animateCarPopIn();
      }
      
      return annot;
    } catch (e) {
      debugPrint('[CarIcon] PointAnnotation creation FAILED: $e');
      return null;
    } finally {
      _carAnnotCreating = false;
    }
  }

  /// Pop-in animation for the car marker: 0.01 → 0.70 → 0.55 → 0.60 over 400ms.
  /// Makes the car appear with a satisfying bounce when first GPS arrives.
  void _animateCarPopIn() {
    if (_carAnnot == null || _carAnnotMgr == null) return;
    _animScheduler.schedule(
      durationMs: 400,
      onTick: (t) {
        double scale;
        if (t < 0.35) {
          scale = 0.01 + (_kCarAnnotScale * 1.4 - 0.01) * (t / 0.35);
        } else if (t < 0.65) {
          scale = _kCarAnnotScale * 1.4 + (_kCarAnnotScale * 0.9 - _kCarAnnotScale * 1.4) * ((t - 0.35) / 0.3);
        } else {
          scale = _kCarAnnotScale * 0.9 + (_kCarAnnotScale - _kCarAnnotScale * 0.9) * ((t - 0.65) / 0.35);
        }
        try {
          _carAnnotMgr!.update(_carAnnot!..iconSize = scale);
        } catch (_) {}
      },
    );
  }

  Future<void> _updateStaticAnnotationsOnce() async {
    if (kIsWeb) {
      _webCreateStaticAnnotationsOnce();
      return;
    }
    if (_staticAnnotsDone) return;
    final pointMgr = _pointAnnotMgr;
    final polyMgr = _polylineAnnotMgr;
    if (pointMgr == null || polyMgr == null) return;
    // When using modular annotations, check modular state; otherwise check legacy state
    final pinsReady = _mapAnnotations != null
        ? _mapAnnotations!.hasPins
        : (_pickupPinBytes != null && _dropoffPinBytes != null);
    if (!pinsReady) return;
    // During arriving/arrived: allow pins even when route is minimal (trip route is dimmed background)
    if (_routePts.length < 2 && _tripRoutePts.length < 2 && _phase != _TrackPhase.arriving && _phase != _TrackPhase.arrived) return;
    _staticAnnotsDone = true; // mark before await to prevent double-creation

    // ── Draw dimmed trip route (pickup→dropoff) — visible in all phases ──
    // Use modular route component if available, fallback to legacy
    if (_mapRoute != null) {
      await _mapRoute!.drawDimmedRoute(opacity: 0.20, width: 4.0);
    } else {
      final dimmedPts = _tripRoutePts.isNotEmpty ? _tripRoutePts : _routePts;
      if (dimmedPts.length >= 2) {
        final safeGeom = safeLineString(dimmedPts);
        if (safeGeom != null) {
          try {
            _dimmedRouteAnnot ??= await polyMgr.create(mapbox.PolylineAnnotationOptions(
              geometry: safeGeom,
              lineColor: const Color(0xFFFFD700).withValues(alpha: 0.20).toARGB32(),
              lineWidth: 4.0,
              lineJoin: mapbox.LineJoin.ROUND,
            ));
          } catch (e) {
            debugPrint('[TrackingMap] Failed to create dimmed route: $e');
          }
        }
      }
    }

    // Use modular annotations component if available
    if (_mapAnnotations != null) {
      await _mapAnnotations!.createAnnotations(
        pickupLatLng: widget.pickupLatLng,
        dropoffLatLng: widget.dropoffLatLng,
      );
    } else {
      // Pickup pin — legacy path. `_showPickupPin` was written twice and
      // read nowhere, so this recreated the pin after the rider boarded
      // and it sat on the map for the rest of the trip.
      if (_pickupPinBytes != null && _showPickupPin) {
        final pickupPoint = safePoint(widget.pickupLatLng.longitude, widget.pickupLatLng.latitude);
        if (pickupPoint != null) {
          try {
            _pickupAnnot ??= await pointMgr.create(mapbox.PointAnnotationOptions(
              geometry: pickupPoint,
              image: _pickupPinBytes!,
              iconSize: 0.55,
              iconAnchor: mapbox.IconAnchor.BOTTOM,
              iconOffset: [0, 0],
            ));
          } catch (e) {
            debugPrint('[TrackingMap] Failed to create pickup pin: $e');
          }
        }
      } else {
        debugPrint('[TrackingMap] Pickup pin bytes not ready — will retry');
      }

      // Dropoff pin — always show so rider can see full trip plan
      _addDropoffPin();
    }

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
    if (kIsWeb) {
      if (_dropoffPinAdded) return;
      _dropoffPinAdded = true;
      _webMapCtrl?.addMarker(
        'dropoff',
        widget.dropoffLatLng.longitude,
        widget.dropoffLatLng.latitude,
        iconBytes: _dropoffPinBytes,
      );
      return;
    }
    if (_dropoffPinAdded) return;
    final pointMgr = _pointAnnotMgr;
    if (pointMgr == null || _dropoffPinBytes == null) return;
    _dropoffPinAdded = true;
    final dropoffPoint = safePoint(widget.dropoffLatLng.longitude, widget.dropoffLatLng.latitude);
    if (dropoffPoint == null) return;
    try {
      _dropoffAnnot ??= await pointMgr.create(mapbox.PointAnnotationOptions(
        geometry: dropoffPoint,
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
          scale = 0.01 + (0.62 - 0.01) * (t / 0.4);
        } else if (t < 0.7) {
          scale = 0.62 + (0.50 - 0.62) * ((t - 0.4) / 0.3);
        } else {
          scale = 0.50 + (0.55 - 0.50) * ((t - 0.7) / 0.3);
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
    // The map component holds its own copy and its own draw flag. Without
    // this it still has the approach route and refuses to draw again.
    _syncRouteToMap();
    _startAnimatedRouteDraw();
  }

  /// Pop-out animation for the pickup pin when driver picks up rider.
  /// Grows to 1.6x then shrinks to 0 and removes the annotation.
  void _popOutPickupPin() {
    if (_pickupPopping) return;
    _pickupPopping = true;
    if (kIsWeb) {
      // No pop-out sprite anim on web — just remove the marker.
      _webMapCtrl?.removeMarker('pickup');
      _showPickupPin = false;
      _pickupPopping = false;
      return;
    }
    // Use modular component if available
    if (_mapAnnotations != null) {
      _mapAnnotations!.popOutPickupPin().then((_) {
        _showPickupPin = false;
        _pickupPopping = false;
      });
      return;
    }
    // Legacy fallback. The flag goes off BEFORE any early return: it is
    // what gates the pin's (re)creation in _updateAnnotations, and leaving
    // it on when there is nothing to animate is exactly how the pickup pin
    // resurrected and sat next to the moving car for the whole trip.
    _showPickupPin = false;
    if (_pickupAnnot == null || _pointAnnotMgr == null) {
      _pickupPopping = false;
      return;
    }
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
    if (kIsWeb) {
      // No progressive draw on web — the gold polyline appears complete.
      if (_routeDrawDone || _routePts.length < 2) return;
      _routeDrawDone = true;
      _webDrawGoldRoute(_routePts);
      return;
    }
    if (_routeDrawDone || _routePts.length < 2) return;
    _routeDrawDone = true;

    // Use modular route component if available
    if (_mapRoute != null) {
      _mapRoute!.startAnimatedRouteDraw(this, onComplete: () {
        // Route draw complete
      });
      return;
    }

    // Legacy fallback
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
      lineWidth: 4.0, lineJoin: mapbox.LineJoin.ROUND,
    )); } catch (_) {}
  }

  void _updateRouteLayers(mapbox.PolylineAnnotationManager mgr, mapbox.LineString geom) {
    try {
      if (_remainingRouteAnnot != null) mgr.update(_remainingRouteAnnot!..geometry = geom);
    } catch (_) {}
  }

  /// Adopt a re-routed polyline (already spliced by RouteSplice.splice) as
  /// the active route, swapping the line on screen without a flicker.
  ///
  /// Called by _rerouteFromCurrentPos. The order matters: the data side goes
  /// first because the projection, the erase-behind-the-car and the ETA all
  /// read `_routePts`/`_segDist`, and only then the visual swap happens —
  /// there is never a moment where the route is missing from the map.
  /// The camera is untouched: the chase frame keeps following the car.
  Future<void> _applyReroutedPolyline(List<LatLng> spliced) async {
    if (!mounted || spliced.length < 2) return;

    _routePts = spliced;
    // `_tripRoutePts` is NOT updated on purpose: the onTrip frame uses the
    // full pickup→dropoff polyline, and both endpoints are fixed, so framing
    // with the slightly stale trip geometry is fine — replacing it with this
    // car→dropoff splice would collapse the frame to the remaining leg.
    // But the NEW drawn leg can wander outside the frame the original route
    // was fit to — force ONE re-fit so the rerouted line and the dropoff
    // pin come back on screen (2026-09-13).
    _needsTripReframe = true;
    _buildSegDist();
    // resetDraw:false — the line is already on screen. Re-arming the
    // progressive draw would replay the whole "water flowing" reveal from
    // the start of the route, which is exactly the full repaint this
    // partial splice exists to avoid.
    _syncRouteToMap(resetDraw: false);
    _routeDrawDone = true;
    // Resume from where the car actually is on the new geometry: the fetch
    // took a second or two and the driver kept moving the whole time.
    _traveledM = _startMOnCurrentRoute();
    _tgtTraveledM = _traveledM;
    _directTargetPos = null;
    _directTargetBearing = null;

    // Arriving-leg reroute: the 20%-alpha approach underlay _fetchApproachRoute
    // drew still traces the ORIGINAL road. Nothing else can fix it —
    // _updateApproachLine early-returns once the road route is fetched, and
    // the annotation is otherwise only deleted at arrived/trip start — so
    // left alone the rider watches a dim gold line diverge onto streets the
    // driver abandoned. Move it onto the spliced geometry; if the update
    // fails, drop it (per the Mapbox dedup rule: never trust a failed
    // update to have left the old visual in place).
    if (_phase == _TrackPhase.arriving && _approachAnnot != null) {
      final mgr = _polylineAnnotMgr;
      final geom = safeLineString(_routePts);
      if (mgr != null && geom != null) {
        final annot = _approachAnnot!;
        try {
          annot.geometry = geom;
          mgr.update(annot).catchError((_) {
            _approachAnnot = null;
            mgr.delete(annot).catchError((_) {});
          });
        } catch (_) {
          _approachAnnot = null;
          try { mgr.delete(annot).catchError((_) {}); } catch (_) {}
        }
      }
    }

    if (kIsWeb) {
      // setPolyline replaces the 'route' source in place — one frame, no
      // gap, nothing to fade. The next erase tick trims behind the car.
      _webDrawGoldRoute(_routePts);
      return;
    }

    if (_mapRoute != null) {
      await _mapRoute!.crossFadeTo(_routePts, fadeMs: _kRerouteFadeMs);
      return;
    }
    await _crossFadeRemainingRoute(_routePts);
  }

  /// Legacy-annotation twin of TrackingMapRoute.crossFadeTo: the new gold
  /// line comes up from opacity 0 while the old one goes down, and only
  /// then is the old one deleted.
  Future<void> _crossFadeRemainingRoute(List<LatLng> pts) async {
    final mgr = _polylineAnnotMgr;
    if (mgr == null || pts.length < 2) return;
    final geom = safeLineString(pts);
    if (geom == null) return;

    // The progressive draw ticker writes _remainingRouteAnnot from its own
    // captured coordinate list — left running it repaints the new line with
    // the old geometry.
    _routeDrawTicker?.stop();

    final old = _remainingRouteAnnot;
    if (old == null) {
      await _createRouteLayers(mgr, geom);
      return;
    }

    // Freeze the erase across the create() await: _routePts is already the
    // new geometry but _remainingRouteAnnot is still the OLD line, and an
    // erase tick landing in this window would snap the old line onto the
    // new route at full opacity — a hard cut one frame before the fade,
    // which then blends two identical geometries (invisible).
    mapbox.PolylineAnnotation? fresh;
    _routeEraseBusy = true;
    try {
      try {
        fresh = await mgr.create(mapbox.PolylineAnnotationOptions(
          geometry: geom,
          lineColor: const Color(0xFFFFD700).toARGB32(),
          lineWidth: 4.0,
          lineJoin: mapbox.LineJoin.ROUND,
          lineOpacity: 0.0,
        ));
      } catch (_) {}
      // _eraseRouteBehindCar writes _remainingRouteAnnot — point it at the
      // new line now so the road keeps being consumed under the car mid-fade.
      if (fresh != null && mounted) _remainingRouteAnnot = fresh;
    } finally {
      _routeEraseBusy = false;
    }
    // No new line: keep the old one rather than leaving the map bare.
    if (fresh == null) return;
    if (!mounted) {
      try { await mgr.delete(fresh); } catch (_) {}
      return;
    }
    final target = fresh;

    _rerouteFadeTimer?.cancel();
    final sw = Stopwatch()..start();
    _rerouteFadeTimer = Timer.periodic(const Duration(milliseconds: 33), (t) {
      final k = (sw.elapsedMilliseconds / _kRerouteFadeMs).clamp(0.0, 1.0);
      try {
        mgr.update(target..lineOpacity = k).catchError((_) {});
        mgr.update(old..lineOpacity = 1.0 - k).catchError((_) {});
      } catch (_) {}
      if (k >= 1.0) {
        t.cancel();
        _rerouteFadeTimer = null;
        try { mgr.delete(old).catchError((_) {}); } catch (_) {}
      }
    });
  }

  /// Erase the route behind the car: update remaining-route layers to show
  /// only the portion ahead of the current driver position.
  void _eraseRouteBehindCar() {
    if (_routeEraseBusy) return;
    final now = DateTime.now();
    if (now.difference(_lastRouteErase).inMilliseconds <
        _kRouteEraseIntervalMs) {
      return;
    }
    _lastRouteErase = now;

    if (kIsWeb) {
      _webEraseRouteBehindCar();
      return;
    }

    // Use modular route component if available
    if (_mapRoute != null) {
      _mapRoute!.eraseRouteBehindCar(_animPos);
      return;
    }

    // Legacy fallback
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

    // Guard against NaN from interpolation
    if (!isValidLatLng(curLat, curLng)) return;

    // Build remaining coords: interpolated current point + all points ahead
    final ahead = hi < _routePts.length ? _routePts.length - hi : 0;
    final remaining = <mapbox.Position>[
      mapbox.Position(curLng, curLat),
      ...List.generate(
        ahead,
        (i) => mapbox.Position(_routePts[hi + i].longitude, _routePts[hi + i].latitude),
      ),
    ];
    // Filter any NaN coords that may have slipped through
    final validRemaining = remaining.where((p) => isValidLatLng(p.lat.toDouble(), p.lng.toDouble())).toList();
    if (validRemaining.length < 2) return;

    final geom = mapbox.LineString(coordinates: validRemaining);
    if (_remainingRouteAnnot == null) return;
    // Hold the gate until the write lands, so the next frames skip instead
    // of stacking writes the SDK would silently drop.
    _routeEraseBusy = true;
    try {
      mgr
          .update(_remainingRouteAnnot!..geometry = geom)
          .whenComplete(() => _routeEraseBusy = false);
    } catch (_) {
      _routeEraseBusy = false;
    }
  }

  /// Remove the dimmed route (called when transitioning to onTrip gloss route)
  void _removeDimmedRoute() {
    if (kIsWeb) {
      _webMapCtrl?.removePolyline('dimmed');
      return;
    }
    // Use modular route component if available
    if (_mapRoute != null) {
      _mapRoute!.removeDimmedRoute();
      return;
    }
    // Legacy fallback
    final mgr = _polylineAnnotMgr;
    if (mgr == null || _dimmedRouteAnnot == null) return;
    try { mgr.delete(_dimmedRouteAnnot!); } catch (_) {}
    _dimmedRouteAnnot = null;
  }

  void _updateApproachLine() {
    if (kIsWeb) {
      _webUpdateApproachLine();
      return;
    }
    // When approach route is fetched (road-following), the main route polyline
    // IS the approach — no need for an extra straight line.
    if (_approachRouteFetched) return;

    // Throttle: update every 500ms
    final now = DateTime.now();
    if (now.difference(_lastApproachUpdate).inMilliseconds < 500) return;
    _lastApproachUpdate = now;

    // Only show during arriving phase — and never as a FINAL state. This
    // straight driver→pickup line is a stopgap while the road route is in
    // flight; once the fetch has failed for good (_approachRouteFailed) it
    // would be all the rider ever sees, and a line cutting across blocks
    // lies about where the driver is coming from. Pull it and leave the
    // dimmed trip route and the pins to carry the screen.
    final shouldShow = _phase == _TrackPhase.arriving && !_approachRouteFailed;

    if (!shouldShow) {
      // Remove existing approach line
      if (_mapRoute != null) {
        _mapRoute!.removeApproach();
      } else {
        final mgr = _polylineAnnotMgr;
        if (mgr != null && _approachAnnot != null && !_approachLineRemoved) {
          _approachLineRemoved = true;
          try { mgr.delete(_approachAnnot!); } catch (_) {}
          _approachAnnot = null;
        }
      }
      return;
    }

    // Use modular route component if available
    if (_mapRoute != null) {
      _mapRoute!.drawApproach(_animPos, widget.pickupLatLng);
      return;
    }

    // Legacy fallback
    final mgr = _polylineAnnotMgr;
    if (mgr == null) return;

    final approachGeom = safeLineString([
      _animPos,
      widget.pickupLatLng,
    ]);
    if (approachGeom == null) return;

    if (_approachAnnot == null) {
      // Gloss gold line (matches main route style) from driver → pickup
      mgr.create(mapbox.PolylineAnnotationOptions(
        geometry: approachGeom,
        lineColor: const Color(0xFFFFD700).toARGB32(),
        lineWidth: 4.0,
        lineJoin: mapbox.LineJoin.ROUND,
      )).then((annot) { _approachAnnot = annot; }).catchError((_) {});
    } else {
      try { mgr.update(_approachAnnot!..geometry = approachGeom); } catch (_) {}
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
    if (kIsWeb) {
      if (_arrivedStateInitialized) return;
      _arrivedStateInitialized = true;

      // Stop all camera movement — same contract as the native path.
      _shouldFollowDriver = false;
      _cameraFollowTimer?.cancel();
      _cameraFollowTimer = null;

      final web = _webMapCtrl;
      web?.removePolyline('approach');
      web?.removePolyline('route');

      // Trip route (pickup→dropoff) becomes the dimmed preview; the bright
      // draw fires when the rider confirms pickup (_restartRouteAnimation).
      if (_tripRoutePts.isNotEmpty) {
        _routePts = _tripRoutePts;
        _buildSegDist();
        _traveledM = 0;
        _tgtTraveledM = 0;
        _routeDrawDone = false;
        _webDrawDimmedRoute();
      }

      // Fit camera to pickup + dropoff ONCE, then stop.
      Future.delayed(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        _webFitArrivedBounds();
      });
      return;
    }
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
      // Clear the component's draw flag too, or _restartRouteAnimation
      // below finds it already true and draws nothing.
      _syncRouteToMap();
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
    if (kIsWeb) {
      _webFitArrivedBounds();
      return;
    }
    if (_map == null) return;

    final mq = MediaQuery.maybeOf(context)?.padding ?? EdgeInsets.zero;
    final topPad = mq.top;
    final bottomPad = mq.bottom;

    // Use modular camera component if available
    if (_mapCamera != null) {
      _mapCamera!.fitArrivedBounds(
        pickupPos: widget.pickupLatLng,
        dropoffPos: widget.dropoffLatLng,
        routePoints: _tripRoutePts,
        topPadding: topPad + 10 + _topCardHeight + 48,
        bottomPadding: bottomPad + 16 + _bottomCardHeight + 48,
      );
      return;
    }

    // Legacy fallback
    final pts = <LatLng>[
      widget.pickupLatLng,
      widget.dropoffLatLng,
    ];
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
      _map!.flyTo(clampedCam, mapbox.MapAnimationOptions(duration: 1300));
    });
  }

  Future<void> _centerDriverOnArrival() async {
    if (kIsWeb) {
      if (_animPos.latitude == 0 && _animPos.longitude == 0) return;
      _webAutoCameraUntil = DateTime.now().add(const Duration(milliseconds: 1200));
      _webMapCtrl?.flyTo(
        lng: _animPos.longitude,
        lat: _animPos.latitude,
        zoom: 16.4,
        durationMs: 1100,
      );
      return;
    }
    if (_map == null) return;
    final mq = MediaQuery.maybeOf(context)?.padding ?? EdgeInsets.zero;
    final topInset = mq.top + 10 + _topCardHeight + 48;
    final bottomInset = mq.bottom + 16 + _bottomCardHeight + 48;
    // Use modular camera component if available
    if (_mapCamera != null) {
      await _mapCamera!.centerOnDriver(
        driverPos: _animPos,
        topPadding: topInset,
        bottomPadding: bottomInset,
        zoom: 16.4,
        durationMs: 1100,
      );
      return;
    }
    // Legacy fallback
    final point = mapbox.Point(
      coordinates: mapbox.Position(_animPos.longitude, _animPos.latitude),
    );
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
    if (kIsWeb) {
      if (_animPos.latitude == 0 && _animPos.longitude == 0) return;
      _webAutoCameraUntil = DateTime.now().add(const Duration(milliseconds: 1600));
      _webMapCtrl?.flyTo(
        lng: _animPos.longitude,
        lat: _animPos.latitude,
        zoom: 16.5,
        durationMs: 1500,
      );
      return;
    }
    if (_map == null) return;
    final mq = MediaQuery.maybeOf(context)?.padding ?? EdgeInsets.zero;
    final topInset = mq.top + 10 + _topCardHeight + 48;
    final bottomInset = mq.bottom + 16 + _bottomCardHeight + 48;
    // Use modular camera component if available
    if (_mapCamera != null) {
      _mapCamera!.flyToDriverStart(
        driverPos: _animPos,
        topPadding: topInset,
        bottomPadding: bottomInset,
        durationMs: 1500,
      );
      return;
    }
    // Legacy fallback
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

  // ════════════════════════════════════════════════════════════
  //  WEB MAP (Mapbox GL JS) — parity helpers used when kIsWeb.
  //
  //  The native stack (MapboxMap, annotation managers, TrackingMap*
  //  components, chase camera) is untouched; every public entry point
  //  above branches here first so `_map` stays null on web and nothing
  //  native ever runs. Not ported: 3D tilt chase camera, pin pop/spring
  //  sprite animations, progressive route draw — GL JS DOM markers and
  //  GeoJSON polylines cover the essentials instead.
  // ════════════════════════════════════════════════════════════

  List<LngLatPoint> _webPts(List<LatLng> pts) => [
        for (final p in pts) (lng: p.longitude, lat: p.latitude),
      ];

  void _webDrawGoldRoute(List<LatLng> pts) {
    if (pts.length < 2) return;
    _webMapCtrl?.setPolyline('route', _webPts(pts), color: '#FFD700', width: 4);
  }

  void _webDrawDimmedRoute() {
    final pts = _tripRoutePts.isNotEmpty ? _tripRoutePts : _routePts;
    if (pts.length < 2) return;
    _webMapCtrl?.setPolyline(
      'dimmed',
      _webPts(pts),
      color: 'rgba(255,215,0,0.20)',
      width: 4,
    );
  }

  /// Web twin of [_updateStaticAnnotationsOnce]: pins + dimmed trip route,
  /// created once, then the gold route draw and label reveals on the same
  /// cadence as native.
  void _webCreateStaticAnnotationsOnce() {
    if (_staticAnnotsDone) return;
    final web = _webMapCtrl;
    if (web == null) return;
    if (_pickupPinBytes == null || _dropoffPinBytes == null) return;
    if (_routePts.length < 2 &&
        _tripRoutePts.length < 2 &&
        _phase != _TrackPhase.arriving &&
        _phase != _TrackPhase.arrived) {
      return;
    }
    _staticAnnotsDone = true;

    _webDrawDimmedRoute();
    if (_showPickupPin) {
      web.addMarker(
        'pickup',
        widget.pickupLatLng.longitude,
        widget.pickupLatLng.latitude,
        iconBytes: _pickupPinBytes,
      );
    }
    _dropoffPinAdded = true;
    web.addMarker(
      'dropoff',
      widget.dropoffLatLng.longitude,
      widget.dropoffLatLng.latitude,
      iconBytes: _dropoffPinBytes,
    );

    _fitRouteBounds();
    // Gold route draw, mirroring the native cinematic delay.
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _startAnimatedRouteDraw();
    });
    if (_pickupPinWithLabelBytes != null && !_pickupLabelRevealed) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) _revealPickupLabel();
      });
    }
    if (_dropoffPinWithLabelBytes != null && !_dropoffLabelRevealed) {
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (mounted) _revealDropoffLabel();
      });
    }
  }

  /// Web twin of the car-annotation update: one DOM marker, created on the
  /// first valid fix and moved every frame after.
  void _webUpdateCarMarker() {
    final web = _webMapCtrl;
    if (web == null) return;

    LatLng effectivePos = _animPos;
    double effectiveBearing = _animBearing;
    if (_animPos.latitude == 0 && _animPos.longitude == 0) {
      final directPos = _directTargetPos;
      if (directPos != null &&
          directPos.latitude != 0 &&
          directPos.longitude != 0) {
        effectivePos = directPos;
        effectiveBearing = _directTargetBearing ?? 0;
        _animPos = effectivePos;
        _animBearing = effectiveBearing;
        _driverPos = effectivePos;
        _driverBearing = effectiveBearing;
      } else {
        return; // No valid position yet — car stays hidden, same as native.
      }
    }
    if (!isValidLatLng(effectivePos.latitude, effectivePos.longitude)) return;

    if (_webCarBearing < 0) {
      _webCarBearing = effectiveBearing;
      web.addMarker(
        'driver',
        effectivePos.longitude,
        effectivePos.latitude,
        iconBytes: _carPngBytes,
        rotation: effectiveBearing,
      );
      return;
    }
    // GL JS markers rebuild from scratch on rotation change — deadband it so
    // a parked driver's GPS wander does not churn the DOM every frame.
    final rot = (effectiveBearing - _webCarBearing).abs() > 3
        ? effectiveBearing
        : null;
    if (rot != null) _webCarBearing = effectiveBearing;
    web.updateMarkerPosition(
      'driver',
      effectivePos.longitude,
      effectivePos.latitude,
      rotation: rot,
    );
  }

  /// Web twin of the native route erase: same math, written as a GeoJSON
  /// polyline update instead of a PolylineAnnotation update.
  void _webEraseRouteBehindCar() {
    final web = _webMapCtrl;
    if (web == null || _segDist.isEmpty || _routePts.length < 2) return;
    if (!_routeDrawDone) return;

    final dist = _traveledM;
    if (dist <= 0) return;

    int lo = 0, hi = _segDist.length - 1;
    while (lo < hi - 1) {
      final mid = (lo + hi) >> 1;
      if (_segDist[mid] <= dist) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final segLen = _segDist[hi] - _segDist[lo];
    final t = segLen > 0.01
        ? ((dist - _segDist[lo]) / segLen).clamp(0.0, 1.0)
        : 0.0;
    final a = _routePts[lo];
    final b = _routePts[hi];
    final curLat = a.latitude + (b.latitude - a.latitude) * t;
    final curLng = a.longitude + (b.longitude - a.longitude) * t;
    if (!isValidLatLng(curLat, curLng)) return;

    final remaining = <LngLatPoint>[
      (lng: curLng, lat: curLat),
      for (int i = hi; i < _routePts.length; i++)
        (lng: _routePts[i].longitude, lat: _routePts[i].latitude),
    ];
    if (remaining.length < 2) return;
    web.setPolyline('route', remaining, color: '#FFD700', width: 4);
  }

  /// Web twin of the straight approach line (driver → pickup) shown until
  /// the road-following approach route arrives.
  void _webUpdateApproachLine() {
    final web = _webMapCtrl;
    if (web == null) return;
    // Main route polyline IS the approach once the fetched route lands.
    if (_approachRouteFetched) return;

    final now = DateTime.now();
    if (now.difference(_lastApproachUpdate).inMilliseconds < 500) return;
    _lastApproachUpdate = now;

    // _approachRouteFailed: same rule as native — the straight stopgap is
    // never the final answer, no line beats a line that lies.
    if (_phase != _TrackPhase.arriving ||
        _approachRouteFailed ||
        (_animPos.latitude == 0 && _animPos.longitude == 0)) {
      web.removePolyline('approach');
      return;
    }
    web.setPolyline('approach', [
      (lng: _animPos.longitude, lat: _animPos.latitude),
      (lng: widget.pickupLatLng.longitude, lat: widget.pickupLatLng.latitude),
    ], color: '#FFD700', width: 4);
  }

  /// Web twin of [_fitRouteBounds]: same point sets and card-aware padding,
  /// one fitBounds call instead of cameraForCoordinatesPadding + flyTo.
  void _webFitRouteBounds() {
    final web = _webMapCtrl;
    if (web == null || (_routePts.isEmpty && _tripRoutePts.isEmpty)) return;
    // Arrived/onTrip phases own their camera elsewhere, same as native.
    if (_phase == _TrackPhase.arrived) return;
    if (_phase == _TrackPhase.onTrip ||
        _phase == _TrackPhase.nearDestination) {
      return;
    }

    final pts = <LatLng>[
      widget.pickupLatLng,
      widget.dropoffLatLng,
    ];
    if (_animPos.latitude != 0 && _animPos.longitude != 0) pts.add(_animPos);
    pts.addAll(_routePts);
    if (_phase == _TrackPhase.arriving) pts.addAll(_tripRoutePts);

    final mq = MediaQuery.maybeOf(context)?.padding ?? EdgeInsets.zero;
    _webAutoCameraUntil = DateTime.now().add(const Duration(milliseconds: 1000));
    web.fitBounds(
      _webPts(pts),
      paddingTop: mq.top + 10 + _topCardHeight + 64,
      paddingBottom: mq.bottom + 16 + _bottomCardHeight + 64,
      paddingLeft: 44,
      paddingRight: 44,
      durationMs: 800,
    );
  }

  /// Web twin of [_fitArrivedBounds]: pickup + dropoff + trip route, once.
  void _webFitArrivedBounds() {
    final web = _webMapCtrl;
    if (web == null) return;
    final pts = <LatLng>[
      widget.pickupLatLng,
      widget.dropoffLatLng,
      ..._tripRoutePts,
    ];
    final mq = MediaQuery.maybeOf(context)?.padding ?? EdgeInsets.zero;
    _webAutoCameraUntil = DateTime.now().add(const Duration(milliseconds: 1400));
    web.fitBounds(
      _webPts(pts),
      paddingTop: mq.top + 10 + _topCardHeight + 48,
      paddingBottom: mq.bottom + 16 + _bottomCardHeight + 48,
      paddingLeft: 44,
      paddingRight: 44,
      durationMs: 1300,
    );
  }

  /// Web chase camera, driven by the same shared ticker as native.
  ///
  /// No 3D pitch chase (that is the native TrackingMapCamera's job and GL JS
  /// markers do not lie flat anyway): during arriving the camera frames
  //  driver + pickup and tightens as the gap closes; during the trip it
  /// follows the car top-down with the map rotated to heading.
  void _webCameraTick() {
    if (!mounted) return;
    final web = _webMapCtrl;
    if (web == null) return;
    if (_phase == _TrackPhase.arrived || _phase == _TrackPhase.completed) {
      return;
    }

    // Auto-resume after the rider stops panning — same rule as native.
    if (_userControllingCamera) {
      final last = _lastUserCameraInteraction;
      if (last == null ||
          DateTime.now().difference(last).inMilliseconds >
              _kResumeFollowAfterPanMs) {
        _userControllingCamera = false;
        _lastUserCameraInteraction = null;
      } else {
        return;
      }
    }
    if (_animPos.latitude == 0 && _animPos.longitude == 0) return;

    // Throttled: a 60 fps flyTo storms the GL camera for no visible gain.
    final now = DateTime.now();
    if (now.difference(_lastWebCamMove).inMilliseconds < 400) return;
    _lastWebCamMove = now;
    _webAutoCameraUntil = now.add(const Duration(milliseconds: 800));

    // maybeOf: ticker frames can land on a deactivated element. See rule 26.
    final mq = MediaQuery.maybeOf(context);
    if (mq == null) return;
    final topPad = mq.padding.top + 10 + _topCardHeight + 32;
    final bottomPad = mq.padding.bottom + 16 + _bottomCardHeight + 32;

    // Same framing rule as native, so the browser build shows the ride the
    // way the phones do: everything still ahead stays on screen and the
    // zoom tightens by itself. The trip half used to follow the car at a
    // fixed zoom 15.5 with the map turned heading-up — the rider could not
    // see where they were going, only where they were.
    final isOnTrip = _phase == _TrackPhase.onTrip ||
        _phase == _TrackPhase.nearDestination;
    if (_phase != _TrackPhase.arriving && !isOnTrip) return;

    final framePts = isOnTrip ? _tripFramePoints() : _approachFramePoints();
    if (framePts.isEmpty) return;
    web.fitBounds(
      [
        for (final p in framePts)
          if (p.latitude != 0 || p.longitude != 0)
            (lng: p.longitude, lat: p.latitude),
      ],
      paddingTop: topPad,
      paddingBottom: bottomPad,
      paddingLeft: 60,
      paddingRight: 60,
      durationMs: 400,
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
    _startRiderLocationSharing();
  }

  // ── Rider → driver location sharing (pre-pickup only) ──────────────────
  //
  // While the driver is on the way (or waiting at the curb), the rider's
  // own fixes go to the trip room as `rider_location` so the driver sees
  // them walking to the car. Background-capable on purpose: the rider's
  // flow at this point is "confirm and pocket the phone" — minimizing must
  // keep publishing, killing the app leaves the driver the last fix.
  //
  // Privacy: a rider who turned off Location Sharing (privacy_location) does
  // not publish — same toggle GpsService._riderLocationSharingBlocked reads.
  Future<void> _startRiderLocationSharing() async {
    if (kIsWeb) return;
    final tripId = widget.tripId;
    if (tripId == null) return;
    try {
      final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;
      if (!(prefs.getBool('privacy_location') ?? true)) return;
    } catch (_) {}
    if (!mounted) return;
    final s = S.of(context);
    _riderShareStream = ResilientPositionStream(
      label: 'RiderLocShare',
      settings: driverLocationSettings(
        distanceFilter: 2,
        notificationTitle: s.driverLocationNotifTitle,
        notificationText: s.driverLocationNotifOnTrip,
      ),
      onPosition: (pos) {
        if (!mounted) return;
        // The window closed (rider aboard / trip over): stop publishing and
        // tear the background stream down — the puck is native and needs
        // nothing from this.
        if (_phase != _TrackPhase.arriving && _phase != _TrackPhase.arrived) {
          _stopRiderLocationSharing();
          return;
        }
        // ~1 s / >2 m throttle — the stream's own filters get close, this
        // makes it exact so the relay is never spammed.
        final now = DateTime.now();
        final lastAt = _lastRiderShareAt;
        final lastPos = _lastRiderSharePos;
        if (lastAt != null &&
            lastPos != null &&
            now.difference(lastAt).inMilliseconds < 1000 &&
            Geolocator.distanceBetween(lastPos.latitude, lastPos.longitude,
                    pos.latitude, pos.longitude) <
                2) {
          return;
        }
        _lastRiderShareAt = now;
        _lastRiderSharePos = LatLng(pos.latitude, pos.longitude);
        SocketService.sendRiderLocation(
          tripId: tripId,
          lat: pos.latitude,
          lng: pos.longitude,
          heading: pos.heading,
          speed: pos.speed,
          capturedAtMs: pos.timestamp.millisecondsSinceEpoch,
        );
      },
    )..start();
  }

  void _stopRiderLocationSharing() {
    final stream = _riderShareStream;
    _riderShareStream = null;
    if (stream != null) unawaited(stream.stop());
  }
}
