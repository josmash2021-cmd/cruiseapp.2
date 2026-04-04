part of 'ride_request_screen.dart';

// ════════════════════════════════════════════════════════════
//  MAP — annotations, cinematic, route drawing
// ════════════════════════════════════════════════════════════

extension _RideRequestMap on _RideRequestScreenState {

  /// Detect what icon to show on the dropoff pin based on address text.
  _PinIcon _detectDropoffType(String address) {
    final lower = address.toLowerCase();
    // Airport keywords
    if (lower.contains('airport') ||
        lower.contains('aeropuerto') ||
        lower.contains(' mia ') ||
        lower.contains(' jfk ') ||
        lower.contains(' lax ') ||
        lower.contains(' ord ') ||
        lower.contains(' atl ') ||
        lower.contains(' sfo ') ||
        lower.contains(' dfw ') ||
        lower.contains('intl') ||
        lower.contains('terminal') ||
        lower.contains('aviation')) {
      return _PinIcon.airplane;
    }
    // Commerce / business keywords
    if (lower.contains('mall') ||
        lower.contains('plaza') ||
        lower.contains('store') ||
        lower.contains('shop') ||
        lower.contains('market') ||
        lower.contains('restaurant') ||
        lower.contains('hotel') ||
        lower.contains('hospital') ||
        lower.contains('clinic') ||
        lower.contains('center') ||
        lower.contains('centre') ||
        lower.contains('office') ||
        lower.contains('building') ||
        lower.contains('tower') ||
        lower.contains('suite') ||
        lower.contains('ste ') ||
        lower.contains('walmart') ||
        lower.contains('target') ||
        lower.contains('costco') ||
        lower.contains('starbucks') ||
        lower.contains('mcdonalds') ||
        lower.contains("mcdonald's") ||
        lower.contains('gym') ||
        lower.contains('fitness') ||
        lower.contains('church') ||
        lower.contains('school') ||
        lower.contains('university') ||
        lower.contains('college') ||
        lower.contains('stadium') ||
        lower.contains('arena') ||
        lower.contains('museum') ||
        lower.contains('cinema') ||
        lower.contains('theater') ||
        lower.contains('theatre') ||
        lower.contains('park ') ||
        lower.contains('banco') ||
        lower.contains('bank') ||
        lower.contains('station')) {
      return _PinIcon.store;
    }
    // Default: house / residential
    return _PinIcon.house;
  }

  Future<Uint8List> _buildGoldPin({
    _PinIcon icon = _PinIcon.none,
    bool isPickup = true,
  }) async {
    return renderCircularPinBytes(
      icon: _pinIconToCircular(icon),
      isPickup: isPickup,
      radius: 28,
    );
  }

  /// Render a combined pin + label bitmap as a single image.
  /// When [labelOnLeft] is false: pin on LEFT, label on RIGHT (pickup default).
  /// When [labelOnLeft] is true:  label on LEFT, pin on RIGHT (dropoff default).
  /// The canvas is padded so the pin tip is at exact bottom-center,
  /// allowing `iconAnchor: BOTTOM` with zero offset.
  Future<(Uint8List, Offset, Uint8List)> _buildPinWithLabel({
    required String text,
    bool isPickup = true,
    String? etaText,
    _PinIcon icon = _PinIcon.none,
    bool labelOnLeft = false,
  }) async {
    final label = _truncateHalf(text);
    final showEta = etaText != null && etaText.isNotEmpty;

    // ── Pin dimensions ──
    const pinSize = 130.0;

    // ── Measure label text ──
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          fontSize: 34,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 550);

    TextPainter? etaPainter;
    if (showEta) {
      etaPainter = TextPainter(
        text: TextSpan(
          text: etaText,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: 0.3,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: 300);
    }

    // ── Label box sizing ──
    const hPad = 18.0;
    const gap = 10.0;
    const dotSize = 12.0;
    const etaBoxPad = 10.0;
    final etaW = etaPainter != null
        ? etaPainter.width + etaBoxPad * 2 + gap
        : 0.0;
    final labelW = hPad + dotSize + gap + textPainter.width + etaW + hPad + 10;
    const labelH = 95.0;
    const pinLabelGap = 12.0;

    // ── Pin display dimensions (GoldenPinPainter: height = width × 1.30) ──
    // The 2× image must be scaled to its logical size before drawing.
    const double pinDisplayW = pinSize;
    const double pinDisplayH = pinSize * 0.92; // includes full tail down to the tip

    // ── Unpadded layout ──
    final rawW = pinDisplayW + pinLabelGap + labelW;
    // Canvas height = full pin height so tip lands at canvas bottom for iconAnchor.BOTTOM
    final totalH = math.max(pinDisplayH, labelH);

    double pinX, labelX;
    if (labelOnLeft) {
      labelX = 0;
      pinX = labelW + pinLabelGap;
    } else {
      pinX = 0;
      labelX = pinDisplayW + pinLabelGap;
    }
    final double pinY = 0.0; // pin top at canvas top → tip exactly at canvas bottom
    // Label centred on pin head (head is at width×0.50 from top ≈ 38.5% of total height)
    final double labelY = (pinDisplayH * 0.385 - labelH / 2.0).clamp(0.0, totalH - labelH);

    // ── Pad canvas so pin tip is at bottom-center ──
    final pinTipX = pinX + pinDisplayW / 2;
    final leftMargin = pinTipX;
    final rightMargin = rawW - pinTipX;
    final maxM = math.max(leftMargin, rightMargin);
    final leftPad = maxM - leftMargin;
    final paddedW = 2 * maxM;

    // Shift drawing positions by leftPad
    final adjPinX = pinX + leftPad;
    final adjLabelX = labelX + leftPad;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, paddedW, totalH));

    // ── Draw circular pin (render and decode) ──
    final pinBytes = await renderCircularPinBytes(
      icon: _pinIconToCircular(icon),
      isPickup: isPickup,
      radius: pinSize / 2,
    );
    final codec = await ui.instantiateImageCodec(pinBytes);
    final frame = await codec.getNextFrame();
    final pinImage = frame.image;
    // Scale the 2× image into the logical display rect so the tip lands at canvas bottom
    final srcRect = Rect.fromLTWH(0, 0, pinImage.width.toDouble(), pinImage.height.toDouble());
    final dstRect = Rect.fromLTWH(adjPinX, pinY, pinDisplayW, pinDisplayH);
    canvas.drawImageRect(pinImage, srcRect, dstRect, Paint());

    // If airport, overlay a golden departure icon on the pin head
    if (icon == _PinIcon.airplane) {
      final iconTp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(Icons.flight_takeoff_rounded.codePoint),
          style: TextStyle(
            fontSize: pinDisplayW * 0.34,
            fontFamily: Icons.flight_takeoff_rounded.fontFamily,
            package: Icons.flight_takeoff_rounded.fontPackage,
            color: Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final headCY = pinY + pinDisplayH * 0.385; // head centre at 38.5% of pin height
      iconTp.paint(
        canvas,
        Offset(
          adjPinX + pinDisplayW / 2 - iconTp.width / 2,
          headCY - iconTp.height / 2,
        ),
      );
    }

    // ── Draw label box ──
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(adjLabelX, labelY, labelW, labelH),
      const Radius.circular(12),
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

    // ETA badge
    if (showEta && etaPainter != null) {
      final etaBoxW = etaPainter.width + etaBoxPad * 2;
      final etaRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, labelY + (labelH - 28) / 2, etaBoxW, 28),
        const Radius.circular(8),
      );
      canvas.drawRRect(
        etaRect,
        Paint()..color = Colors.white.withValues(alpha: 0.14),
      );
      etaPainter.paint(
        canvas,
        Offset(x + etaBoxPad, labelY + (labelH - etaPainter.height) / 2),
      );
      x += etaBoxW + gap;
    }

    // Color dot
    canvas.drawCircle(
      Offset(x + dotSize / 2, labelY + labelH / 2),
      dotSize / 2,
      Paint()..color = isPickup ? Colors.green : _gold,
    );
    x += dotSize + gap;

    // Address text
    textPainter.paint(
      canvas,
      Offset(x, labelY + (labelH - textPainter.height) / 2),
    );

    final picture = recorder.endRecording();
    // Use floor to avoid transparent padding below the pin tip
    final img = await picture.toImage(paddedW.floor().clamp(1, 9999), totalH.floor().clamp(1, 9999));
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);

    // Anchor: pin tip is now at bottom-center by construction
    const anchorOffset = Offset(0.5, 1.0);

    final rawBytes = bytes!.buffer.asUint8List();
    return (rawBytes, anchorOffset, rawBytes);
  }

  /// Render a standalone circular pin (no label) as raw bytes.
  Future<(Uint8List, Uint8List)> _buildStandalonePin({
    _PinIcon icon = _PinIcon.none,
    bool isPickup = true,
  }) async {
    // Airport: clean departure icon only
    if (icon == _PinIcon.airplane) {
      final bytes = await _buildAirportIconBytes(100);
      return (bytes, bytes);
    }
    final bytes = await renderCircularPinBytes(
      icon: _pinIconToCircular(icon),
      isPickup: isPickup,
      radius: 32,
    );
    return (bytes, bytes);
  }

  /// Render a clean golden flight_takeoff icon (no background shape).
  Future<Uint8List> _buildAirportIconBytes(double dim) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, dim, dim));

    // Drop shadow behind the icon for map contrast
    final shadow = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(Icons.flight_takeoff_rounded.codePoint),
        style: TextStyle(
          fontSize: dim * 0.72,
          fontFamily: Icons.flight_takeoff_rounded.fontFamily,
          package: Icons.flight_takeoff_rounded.fontPackage,
          color: Colors.black.withValues(alpha: 0.45),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    shadow.paint(
      canvas,
      Offset((dim - shadow.width) / 2 + 1, (dim - shadow.height) / 2 + 2),
    );

    // Golden departure icon
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(Icons.flight_takeoff_rounded.codePoint),
        style: TextStyle(
          fontSize: dim * 0.72,
          fontFamily: Icons.flight_takeoff_rounded.fontFamily,
          package: Icons.flight_takeoff_rounded.fontPackage,
          color: _gold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset((dim - tp.width) / 2, (dim - tp.height) / 2),
    );

    final picture = recorder.endRecording();
    final img = await picture.toImage(dim.toInt(), dim.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  /// Draw a teardrop location pin.
  /// The tip points DOWN and sits at (ox + size/2, oy + size) — the coordinate.
  /// A fade gradient blends the tip into the route-line colour.
  void _drawGoldPinAt(
    Canvas canvas,
    double ox,
    double oy,
    double size, {
    _PinIcon icon = _PinIcon.none,
  }) {
    final cx = ox + size / 2;      // horizontal center
    final tipY = oy + size;         // tip of the pin = coordinate point
    final r = size * 0.32;          // radius of the round head
    final headCY = oy + r + size * 0.04; // vertical center of the round head

    // ── Build teardrop path ──
    // Round head (top) + two bezier curves tapering to a tip (bottom).
    final path = Path();
    // Start at the left side of the head at its vertical center
    path.moveTo(cx - r, headCY);
    // Arc the top half of the head
    path.arcTo(
      Rect.fromCircle(center: Offset(cx, headCY), radius: r),
      math.pi,        // start: left
      -math.pi,       // sweep: counter-clockwise top
      false,
    );
    // Right side bezier curving to the tip
    path.cubicTo(
      cx + r,       headCY + r * 1.0,
      cx + r * 0.22, tipY - size * 0.04,
      cx,            tipY,
    );
    // Left side bezier back to start
    path.cubicTo(
      cx - r * 0.22, tipY - size * 0.04,
      cx - r,        headCY + r * 1.0,
      cx - r,        headCY,
    );
    path.close();

    // ── Drop shadow ──
    canvas.drawPath(
      path.shift(const Offset(0, 3)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.32)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    // ── Fill teardrop with gold ──
    canvas.drawPath(path, Paint()..color = _gold);

    // ── White inner stroke ──
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = Colors.white.withValues(alpha: 0.22),
    );

    // ── Subtle highlight on top-left ──
    canvas.drawCircle(
      Offset(cx - r * 0.25, headCY - r * 0.25),
      r * 0.42,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    // ── Fade blend at tip: vertical gradient transparent→route-blue ──
    // Covers roughly the bottom 35% of the pin area, softening the tip.
    final fadeTop = headCY + r * 0.8;
    canvas.drawRect(
      Rect.fromLTRB(cx - r, fadeTop, cx + r, tipY),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, fadeTop),
          Offset(cx, tipY),
          [Colors.transparent, const Color(0x885BA3F5)],
        )
        ..blendMode = BlendMode.srcATop,
    );

    // Icon center = center of the round head
    final cy = headCY; // alias so icon drawing code below still works

    // Draw icon directly on pin — modern filled style
    const iconColor = Color(0xFFFFFFFF);
    final iconPaint = Paint()
      ..color = iconColor
      ..isAntiAlias = true;
    final iconStrokePaint = Paint()
      ..color = iconColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = size * 0.025
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    switch (icon) {
      case _PinIcon.person:
        final s = size * 0.12;
        // Head — filled circle
        canvas.drawCircle(Offset(cx, cy - s * 0.65), s * 0.52, iconPaint);
        // Body — filled rounded shoulders
        final body = RRect.fromRectAndCorners(
          Rect.fromLTRB(
            cx - s * 0.9,
            cy + s * 0.15,
            cx + s * 0.9,
            cy + s * 1.05,
          ),
          topLeft: Radius.circular(s * 0.9),
          topRight: Radius.circular(s * 0.9),
          bottomLeft: Radius.circular(s * 0.2),
          bottomRight: Radius.circular(s * 0.2),
        );
        canvas.drawRRect(body, iconPaint);
        break;

      case _PinIcon.house:
        final s = size * 0.12;
        // Roof (filled triangle)
        final roof = Path()
          ..moveTo(cx, cy - s * 1.25)
          ..lineTo(cx - s * 1.15, cy - s * 0.1)
          ..lineTo(cx + s * 1.15, cy - s * 0.1)
          ..close();
        canvas.drawPath(roof, iconPaint);
        // House body (filled rect)
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(
              cx - s * 0.8,
              cy - s * 0.1,
              cx + s * 0.8,
              cy + s * 0.9,
            ),
            Radius.circular(s * 0.08),
          ),
          iconPaint,
        );
        // Door cutout (dark)
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(
              cx - s * 0.22,
              cy + s * 0.3,
              cx + s * 0.22,
              cy + s * 0.9,
            ),
            Radius.circular(s * 0.15),
          ),
          Paint()..color = _gold,
        );
        break;

      case _PinIcon.store:
        final s = size * 0.12;
        // Store body (filled)
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(
              cx - s * 1.0,
              cy - s * 0.3,
              cx + s * 1.0,
              cy + s * 1.0,
            ),
            Radius.circular(s * 0.1),
          ),
          iconPaint,
        );
        // Awning (filled with scallops)
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTRB(
              cx - s * 1.1,
              cy - s * 1.0,
              cx + s * 1.1,
              cy - s * 0.3,
            ),
            topLeft: Radius.circular(s * 0.2),
            topRight: Radius.circular(s * 0.2),
          ),
          iconPaint,
        );
        // Scallop cutouts
        for (double dx = -0.7; dx <= 0.71; dx += 0.7) {
          canvas.drawCircle(
            Offset(cx + s * dx, cy - s * 0.3),
            s * 0.24,
            Paint()..color = _gold,
          );
        }
        // Window cutout
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(
              cx - s * 0.7,
              cy - s * 0.05,
              cx - s * 0.1,
              cy + s * 0.5,
            ),
            Radius.circular(s * 0.08),
          ),
          Paint()..color = _gold,
        );
        // Door cutout
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(
              cx + s * 0.1,
              cy - s * 0.05,
              cx + s * 0.75,
              cy + s * 1.0,
            ),
            Radius.circular(s * 0.08),
          ),
          Paint()..color = _gold,
        );
        break;

      case _PinIcon.airplane:
        // Handled externally — standalone pins use _buildAirportIconBytes,
        // pin-with-label overlays the icon after drawing the teardrop.
        break;

      case _PinIcon.none:
        break;
    }
  }

  // ── User location dot — hidden on ride request map ──
  Future<void> _updateUserDotAnnotation() async {
    // No GPS dot shown on this screen — pickup pin already marks the user's location
  }

  void _drawRoute() {
    final s = _ctrl.state;
    if (s.route == null) return;
    // Prevent resetting a cinematic that is already in progress
    if (_cinematicRunning) return;
    _showPinLabels = true;
    final pts = _capRouteEndpoints(List<LatLng>.from(s.route!.points));
    _buildRouteMarkers();
    _resetCinematic();
    _startCinematicSequence(pts);
  }

  /// Reset all cinematic animation state so sequence can replay from scratch.
  void _resetCinematic() {
    _cinematicDone = false;
    _cinematicRunning = false;
    _hasAppliedSelectionTilt = false;
    _labelsRevealed = false;

    // Remove listeners then stop running controllers
    _tiltAnim?.removeListener(_applyMapCamera);
    _tiltCtrl?.stop();
    _bearingCtrl?.stop();
    _pinPopCtrl?.stop();
    _labelPopCtrl?.stop();
    _routeDrawTicker?.stop();

    // Reset camera to flat BEFORE any async work so cinematic starts clean
    if (_mapCtrl != null) {
      _mapCtrl!.setCamera(mapbox.CameraOptions(pitch: 0, bearing: 0));
    }

    // Clear existing route annotations so they redraw fresh (fire-and-forget)
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr != null && _routeAnnot != null) {
      final annot = _routeAnnot!;
      _routeAnnot = null;
      polyMgr.delete(annot).catchError((_) {});
    }
  }

  /// Ensure route polyline starts exactly at pickup pin and ends exactly at dropoff pin.
  /// Mapbox Directions returns road-snapped coordinates that may differ from the
  /// raw geocoded pin positions, causing a visible gap between pin and route.
  List<LatLng> _capRouteEndpoints(List<LatLng> pts) {
    // Return road-snapped route as-is from Mapbox Directions API.
    // Do NOT prepend/append raw pin coords — they may be off the road
    // and create visible straight-line segments.
    return pts;
  }

  /// Replay cinematic if route data is available (used by searching phase).
  /// Only triggers if cinematic hasn't already played.
  void _replayCinematicIfRouteAvailable() {
    if (_cinematicDone || _cinematicRunning) return;
    final route = _ctrl.state.route;
    if (route == null || route.points.isEmpty) return;
    final pts = _capRouteEndpoints(List<LatLng>.from(route.points));
    _showPinLabels = true;
    _buildRouteMarkers();
    _resetCinematic();
    _startCinematicSequence(pts);
  }

  /// Cinematic map animation: fit → pin pop → camera tilt/bearing → gold route draw
  Future<void> _startCinematicSequence(List<LatLng> pts) async {
    if (!mounted || _mapCtrl == null) return;
    if (_cinematicRunning) return; // prevent duplicate concurrent sequences
    _cinematicRunning = true;

    // Generate random bearing 5-15° left or right
    final rng = math.Random();
    final degrees = 5.0 + rng.nextDouble() * 10.0;
    _randomBearing = degrees * (rng.nextBool() ? 1.0 : -1.0);

    // 1. Fit camera to full route (flat, no tilt yet)
    _fitRoute(pts);
    await Future.delayed(const Duration(milliseconds: 420));
    if (!mounted) { _cinematicRunning = false; return; }

    // 2. Pin pop first so markers establish visual focus
    _startPinPop();
    await Future.delayed(const Duration(milliseconds: 560));
    if (!mounted) { _cinematicRunning = false; return; }

    // 3. Tilt 0° → 55° + bearing 0° → random, simultaneously (slightly slower)
    _tiltAnim?.removeListener(_applyMapCamera);
    _tiltCtrl?.dispose();
    _tiltCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1050));
    _tiltAnim = Tween<double>(begin: 0.0, end: 55.0).animate(
      CurvedAnimation(parent: _tiltCtrl!, curve: Curves.easeInOutCubic),
    );
    _bearingCtrl?.dispose();
    _bearingCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1050));
    _bearingAnim = Tween<double>(begin: 0.0, end: _randomBearing).animate(
      CurvedAnimation(parent: _bearingCtrl!, curve: Curves.easeInOutCubic),
    );
    _tiltAnim!.addListener(_applyMapCamera);
    await Future.wait([
      _tiltCtrl!.forward(from: 0),
      _bearingCtrl!.forward(from: 0),
    ]);
    if (!mounted) { _cinematicRunning = false; return; }

    // 4. Label bubbles unroll after camera settles
    await Future.delayed(const Duration(milliseconds: 120));
    if (!mounted) { _cinematicRunning = false; return; }
    _unrollLabels();

    // 5. Gold route draws last, with a slightly slower stroke animation
    await Future.delayed(const Duration(milliseconds: 180));
    if (!mounted) { _cinematicRunning = false; return; }
    await _animateGoldRoute(pts);
    if (!mounted) { _cinematicRunning = false; return; }

    // 6. Refit route with panel padding so full route is visible above panel
    _fitRoute(pts, preserveCamera: true);

    // Camera stays tilted at 55° — no reset to flat
    _cinematicDone = true;
    _cinematicRunning = false;
  }

  void _applyMapCamera() {
    if (_mapCtrl == null || !mounted) return;
    _mapCtrl!.setCamera(mapbox.CameraOptions(
      pitch: _tiltAnim?.value,
      bearing: _bearingAnim?.value,
    ));
  }

  /// Smoothly transition the map camera to the angle preset matching [idx].
  /// Called every 10 s in sync with the status-message text cycle.
  void _animateSearchCameraToAngle(int idx) {
    if (_mapCtrl == null || !mounted) return;
    final angleIdx = idx % _searchCameraAngles.length;
    final (targetPitch, targetBearing) = _searchCameraAngles[angleIdx];

    // Determine current camera values (fallback to initial cinematic pose)
    final prevPitch = _searchPitchAnim?.value ?? _tiltAnim?.value ?? 55.0;
    final prevBearing = _searchBearingAnim?.value ?? _bearingAnim?.value ?? _randomBearing;

    // Dispose previous cycling controller
    _searchCamCtrl?.removeListener(_applySearchCamera);
    _searchCamCtrl?.dispose();

    // 1.8 s ease-in-out for a buttery-smooth, cinematic transition
    _searchCamCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _searchPitchAnim = Tween<double>(begin: prevPitch, end: targetPitch).animate(
      CurvedAnimation(parent: _searchCamCtrl!, curve: Curves.easeInOutCubic),
    );
    _searchBearingAnim = Tween<double>(begin: prevBearing, end: targetBearing).animate(
      CurvedAnimation(parent: _searchCamCtrl!, curve: Curves.easeInOutCubic),
    );
    _searchCamCtrl!.addListener(_applySearchCamera);
    _searchCamCtrl!.forward();
  }

  void _applySearchCamera() {
    if (_mapCtrl == null || !mounted) return;
    _mapCtrl!.setCamera(mapbox.CameraOptions(
      pitch: _searchPitchAnim?.value,
      bearing: _searchBearingAnim?.value,
    ));
  }

  void _startPinPop() {
    _pinPopCtrl?.dispose();
    _pinPopCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _pinPopAnim = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.01, end: 1.15).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 60,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.15, end: 0.95).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 20,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 0.95, end: 1.0).chain(CurveTween(curve: Curves.elasticOut)),
        weight: 20,
      ),
    ]).animate(_pinPopCtrl!);
    _pinPopAnim!.addListener(_updatePinScales);
    _pinPopCtrl!.forward(from: 0);
  }

  void _updatePinScales() {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    final s = _pinPopAnim?.value ?? 1.0;
    if (_pickupAnnot != null) {
      _pickupAnnot!.iconSize = s * 0.65;
      mgr.update(_pickupAnnot!);
    }
    if (_dropoffAnnot != null) {
      _dropoffAnnot!.iconSize = s * 0.65;
      mgr.update(_dropoffAnnot!);
    }
  }

  /// Swap pin-only bitmaps to pin+label bitmaps with a spring scale animation.
  /// Creates the effect of address labels "unrolling" from the pin.
  void _unrollLabels() {
    if (_labelsRevealed) return;
    _labelsRevealed = true;

    // Swap annotations to pin+label bitmaps
    _swapToLabelBitmaps();

    // Spring animation: shrink slightly then pop to full size
    _labelPopCtrl?.dispose();
    _labelPopCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _labelPopAnim = TweenSequence<double>([
      // Shrink from current scale to accommodate wider bitmap
      TweenSequenceItem(
        tween: Tween(begin: 0.32, end: 0.72)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 55,
      ),
      // Overshoot
      TweenSequenceItem(
        tween: Tween(begin: 0.72, end: 0.62)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 20,
      ),
      // Settle
      TweenSequenceItem(
        tween: Tween(begin: 0.62, end: 0.65)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 25,
      ),
    ]).animate(_labelPopCtrl!);
    _labelPopAnim!.addListener(_updateLabelScales);
    _labelPopCtrl!.forward(from: 0);
  }

  void _updateLabelScales() {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    final s = _labelPopAnim?.value ?? 0.65;
    if (_pickupAnnot != null) {
      _pickupAnnot!.iconSize = s;
      mgr.update(_pickupAnnot!);
    }
    if (_dropoffAnnot != null) {
      _dropoffAnnot!.iconSize = s;
      mgr.update(_dropoffAnnot!);
    }
  }

  Future<void> _swapToLabelBitmaps() async {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;

    // Swap pickup to pin+label
    if (_pickupAnnot != null && _showPinLabels && _pickupPinWithLabel != null) {
      _pickupAnnot!.image = _pickupPinWithLabel!.$1;
      mgr.update(_pickupAnnot!);
    }

    // Swap dropoff to pin+label (200ms later for staggered effect)
    await Future.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;
    if (_dropoffAnnot != null && _showPinLabels && _dropoffPinWithLabel != null) {
      _dropoffAnnot!.image = _dropoffPinWithLabel!.$1;
      mgr.update(_dropoffAnnot!);
    }
  }

  /// Animate gold route draw at 60fps — smooth progressive reveal.
  /// Uses fire-and-forget updates to avoid frame-skipping from async backpressure.
  Future<void> _animateGoldRoute(List<LatLng> points, [Duration? duration]) async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null || points.length < 2) return;

    // Clear old route if present
    if (_routeAnnot != null) { try { await polyMgr.delete(_routeAnnot!); } catch (_) {} _routeAnnot = null; }

    // Pre-create the annotation with the first 2 points so the ticker
    // never needs to await create() — only fire-and-forget update() calls.
    final initCoords = points.sublist(0, 2).map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    _routeAnnot = await polyMgr.create(mapbox.PolylineAnnotationOptions(
      geometry: mapbox.LineString(coordinates: initCoords),
      lineColor: const Color(0xFFFFD700).toARGB32(),
      lineWidth: 5.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));

    // Adaptive duration: short routes get enough time to look smooth,
    // long routes draw a bit faster so the user doesn't wait.
    final totalMs = duration?.inMilliseconds ??
        (points.length * 6).clamp(800, 2200);

    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    int lastCount = 2;
    bool updating = false;

    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = createTicker((_) {
      if (!mounted) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      if (updating) return;

      final elapsed = stopwatch.elapsedMilliseconds;
      final progress = (elapsed / totalMs).clamp(0.0, 1.0);
      final eased = Curves.easeOutCubic.transform(progress);
      final count = (eased * points.length).round().clamp(2, points.length);

      if (count != lastCount && _routeAnnot != null) {
        lastCount = count;
        final subset = points.sublist(0, count);
        final coords = subset.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        _routeAnnot!.geometry = mapbox.LineString(coordinates: coords);
        updating = true;
        polyMgr.update(_routeAnnot!).then((_) => updating = false).catchError((_) => updating = false);
      }

      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        final fullCoords = points.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        _routeAnnot?.geometry = mapbox.LineString(coordinates: fullCoords);
        if (_routeAnnot != null) polyMgr.update(_routeAnnot!);
        if (!completer.isCompleted) completer.complete();
      }
    });
    _routeDrawTicker!.start();
    return completer.future;
  }

  Future<void> _updateRouteAnnotation(List<LatLng> points) async {
    final mgr = _polylineAnnotMgr;
    if (mgr == null) return;
    // Update single gold line if it exists
    if (_routeAnnot != null) {
      if (points.isEmpty) return;
      final coords = points.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
      final geo = mapbox.LineString(coordinates: coords);
      _routeAnnot!.geometry = geo; await mgr.update(_routeAnnot!);
      return;
    }
    // Fallback: create new single-line route
    if (points.isEmpty) return;
    _routeAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: mapbox.LineString(coordinates: points.map((p) => mapbox.Position(p.longitude, p.latitude)).toList()),
      lineColor: const Color(0xFFFFD700).toARGB32(),
      lineWidth: 5.0,
    ));
  }

  /// Place pickup/dropoff markers immediately and fit camera, even before route loads.
  Future<void> _placeMarkersOnly() async {
    if (_placingMarkers) return; // prevent concurrent duplicate creation
    _placingMarkers = true;
    try {
      final s = _ctrl.state;
      if (s.pickup == null || s.dropoff == null) return;
      final mgr = _pointAnnotMgr;
      if (mgr == null || _goldPinIcon == null) return;

      // Only create if not already placed (synchronous check before any await)
      _pickupAnnot ??= await mgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(s.pickup!.lng, s.pickup!.lat)),
        image: _goldPinIcon!,
        iconSize: 0.85,
        iconAnchor: mapbox.IconAnchor.BOTTOM,
        iconOffset: [0, 0],
      ));
      _dropoffAnnot ??= await mgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(s.dropoff!.lng, s.dropoff!.lat)),
        image: _goldDropoffPinIcon ?? _goldPinIcon!,
        iconSize: 0.85,
        iconAnchor: mapbox.IconAnchor.BOTTOM,
        iconOffset: [0, 0],
      ));
      // Fit camera to show both markers (preserve tilt if cinematic already ran)
      _fitRoute([
        LatLng(s.pickup!.lat, s.pickup!.lng),
        LatLng(s.dropoff!.lat, s.dropoff!.lng),
      ], preserveCamera: _cinematicDone);
      if (mounted) _setState(() {});
    } finally {
      _placingMarkers = false;
    }
  }

  Future<void> _buildRouteMarkers() async {
    final s = _ctrl.state;
    if (s.route == null) return;

    // Detect dropoff type from address
    final dropoffIcon = _detectDropoffType(s.dropoffLabel);

    // Build all 4 variants: pin-only and pin+label for pickup and dropoff
    _pickupPinOnly = await _buildStandalonePin(
      icon: _PinIcon.person,
      isPickup: true,
    );
    _pickupPinWithLabel = await _buildPinWithLabel(
      text: s.pickupLabel.isNotEmpty ? s.pickupLabel : 'Pickup',
      isPickup: true,
      icon: _PinIcon.person,
      labelOnLeft: false, // label on RIGHT of pickup pin
    );
    _dropoffPinOnly = await _buildStandalonePin(
      icon: dropoffIcon,
      isPickup: false,
    );
    _dropoffPinWithLabel = await _buildPinWithLabel(
      text: s.dropoffLabel.isNotEmpty ? s.dropoffLabel : 'Dropoff',
      isPickup: false,
      etaText: s.route!.durationText,
      icon: dropoffIcon,
      labelOnLeft: true, // label on LEFT of dropoff pin
    );

    if (!mounted) return;
    _rebuildMarkers();
  }

  Future<void> _rebuildMarkers() async {
    final s = _ctrl.state;
    if (s.route == null) return;
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;

    // During cinematic, pins start tiny and use pin-ONLY bitmaps (labels animate in later)
    final scale = (!_cinematicDone || (_pinPopCtrl?.isAnimating ?? false)) ? 0.01 : 0.85;
    final useLabels = _labelsRevealed;

    // Pickup marker
    if (_pickupAnnot != null) { try { await mgr.delete(_pickupAnnot!); } catch (_) {} _pickupAnnot = null; }
    if (s.pickup != null) {
      Uint8List? bytes;
      if (useLabels && _showPinLabels && _pickupPinWithLabel != null) {
        bytes = _pickupPinWithLabel!.$1;
      } else if (_pickupPinOnly != null) {
        bytes = _pickupPinOnly!.$1;
      } else {
        bytes = _goldPinIcon;
      }
      if (bytes != null) {
        _pickupAnnot = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(coordinates: mapbox.Position(s.pickup!.lng, s.pickup!.lat)),
          image: bytes,
          iconSize: scale,
          iconAnchor: mapbox.IconAnchor.BOTTOM,
          iconOffset: [0, 0],
        ));
      }
    }

    // Dropoff marker
    if (_dropoffAnnot != null) { try { await mgr.delete(_dropoffAnnot!); } catch (_) {} _dropoffAnnot = null; }
    if (s.dropoff != null) {
      Uint8List? bytes;
      if (useLabels && _showPinLabels && _dropoffPinWithLabel != null) {
        bytes = _dropoffPinWithLabel!.$1;
      } else if (_dropoffPinOnly != null) {
        bytes = _dropoffPinOnly!.$1;
      } else {
        bytes = _goldDropoffPinIcon ?? _goldPinIcon;
      }
      if (bytes != null) {
        _dropoffAnnot = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(coordinates: mapbox.Position(s.dropoff!.lng, s.dropoff!.lat)),
          image: bytes,
          iconSize: scale,
          iconAnchor: mapbox.IconAnchor.BOTTOM,
          iconOffset: [0, 0],
        ));
      }
    }
    if (mounted) _setState(() {});
  }

  // Labels always visible — no toggle behavior
  void _togglePinLabels() {}

  void _fitRoute(List<LatLng> pts, {bool preserveCamera = false}) {
    if (pts.isEmpty || _mapCtrl == null) return;
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final screenH = MediaQuery.of(context).size.height;
    final botPad = MediaQuery.of(context).padding.bottom;
    final phase = _ctrl.state.phase;
    // The map is full-screen and the route sheet covers about 35%.
    // Keep route framed in the visible map area above that sheet.
    final double bottomPad;
    if (phase == RiderPhase.requesting || phase == RiderPhase.searchingDriver) {
      bottomPad = 160 + botPad;
    } else {
      bottomPad = (screenH * 0.35).clamp(190.0, 320.0) + botPad + 20;
    }
    _mapCtrl!.cameraForCoordinatesPadding(
      [mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
       mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat))],
      mapbox.CameraOptions(
        pitch: preserveCamera ? 55.0 : null,
        bearing: preserveCamera ? _randomBearing : null,
      ),
      mapbox.MbxEdgeInsets(top: 60, left: 40, bottom: bottomPad, right: 40),
      null, null,
    ).then((cam) {
      _mapCtrl?.flyTo(cam, mapbox.MapAnimationOptions(duration: 900));
    });
  }

  void _goToTracking() {
    final s = _ctrl.state;
    if (s.pickup == null || s.dropoff == null) {
      _navigatingToTracking = false;
      return;
    }

    // Persist active ride so home screen can show "Resume" banner
    final routePts =
        s.route?.points.map((p) => [p.latitude, p.longitude]).toList() ?? [];
    LocalDataService.setActiveRide(
      ActiveRideInfo(
        pickupLat: s.pickup!.lat,
        pickupLng: s.pickup!.lng,
        dropoffLat: s.dropoff!.lat,
        dropoffLng: s.dropoff!.lng,
        pickupLabel: s.pickupLabel,
        dropoffLabel: s.dropoffLabel,
        driverName: s.driver?.name ?? 'Driver',
        driverRating: s.driver?.rating ?? 4.9,
        vehicleMake: s.driver?.vehicleMake ?? 'Toyota',
        vehicleModel: s.driver?.vehicleModel ?? 'Camry',
        vehicleColor: s.driver?.vehicleColor ?? 'White',
        vehiclePlate: s.driver?.vehiclePlate ?? 'ABC-1234',
        vehicleYear: s.driver?.vehicleYear ?? '2022',
        rideName: s.selectedOption?.name ?? 'Fusion',
        price: s.selectedOption?.priceEstimate ?? 0,
        routePoints: routePts,
        tripId: s.tripId,
        firestoreTripId: s.firestoreTripId,
        driverPhotoUrl: s.driver?.photoUrl,
        driverId: s.driver?.id,
        etaMinutes: s.selectedOption?.etaMinutes,
      ),
    );

    _ctrl.isOnTrackingScreen = true;
    Navigator.of(context).push(
      slideUpFadeRoute(
        RiderTrackingScreen(
          pickupLatLng: LatLng(s.pickup!.lat, s.pickup!.lng),
          dropoffLatLng: LatLng(s.dropoff!.lat, s.dropoff!.lng),
          routePoints: s.route?.points,
          driverName: s.driver?.name ?? 'Driver',
          driverRating: s.driver?.rating ?? 4.9,
          driverPhotoUrl: s.driver?.photoUrl,
          driverId: s.driver?.id,
          driverPhone: s.driver?.phone,
          vehicleMake: s.driver?.vehicleMake ?? 'Toyota',
          vehicleModel: s.driver?.vehicleModel ?? 'Camry',
          vehicleColor: s.driver?.vehicleColor ?? 'White',
          vehiclePlate: s.driver?.vehiclePlate ?? 'ABC-1234',
          vehicleYear: s.driver?.vehicleYear ?? '2022',
          rideName: s.selectedOption?.name ?? 'Fusion',
          price: s.selectedOption?.priceEstimate ?? 0,
          pickupLabel: s.pickupLabel,
          dropoffLabel: s.dropoffLabel,
          tripId: s.tripId,
          firestoreTripId: s.firestoreTripId,
          onTripComplete: () {
            _ctrl.isOnTrackingScreen = false;
            LocalDataService.clearActiveRide();
            // Pop RiderTrackingScreen, then pop RideRequestScreen
            // to return to HomeScreen (Where to? + car options)
            Navigator.of(context).pop(); // pop tracking
            Navigator.of(context).pop(); // pop ride request → back to home
          },
        ),
      ),
    ).whenComplete(() {
      // Reset flag whenever tracking screen is popped (including back gesture or cancel)
      _ctrl.isOnTrackingScreen = false;
    });
  }


  Future<void> _applyDarkNavyGoldTheme(mapbox.MapboxMap ctrl) async {
    await MapTheme.applyNavyGold(ctrl);
  }

  Future<void> _recenterMap() async {
    _programmaticCam = true;
    _setState(() => _userMovedMap = false);
    final s = _ctrl.state;
    // If we have pickup+dropoff, fit both in view
    if (s.pickup != null && s.dropoff != null) {
      final bounds = LatLngBounds(
        southwest: LatLng(
          math.min(s.pickup!.lat, s.dropoff!.lat),
          math.min(s.pickup!.lng, s.dropoff!.lng),
        ),
        northeast: LatLng(
          math.max(s.pickup!.lat, s.dropoff!.lat),
          math.max(s.pickup!.lng, s.dropoff!.lng),
        ),
      );
      final coords = [
        mapbox.Point(coordinates: mapbox.Position(bounds.southwest.longitude, bounds.southwest.latitude)),
        mapbox.Point(coordinates: mapbox.Position(bounds.northeast.longitude, bounds.northeast.latitude)),
      ];
      final screenH = MediaQuery.of(context).size.height;
      final botSafe = MediaQuery.of(context).padding.bottom;
      final bottomPad = (screenH * 0.35).clamp(190.0, 320.0) + botSafe + 20;
      final cam = await _mapCtrl?.cameraForCoordinatesPadding(
        coords, mapbox.CameraOptions(),
        mapbox.MbxEdgeInsets(top: 80, left: 60, bottom: bottomPad, right: 60), null, null,
      );
      if (cam != null) _mapCtrl?.flyTo(cam, mapbox.MapAnimationOptions(duration: 700));
    } else if (_userLocation != null) {
      _mapCtrl?.flyTo(
        mapbox.CameraOptions(center: mapbox.Point(coordinates: mapbox.Position(_userLocation!.longitude, _userLocation!.latitude)), zoom: 15.5),
        mapbox.MapAnimationOptions(duration: 500),
      );
    }
  }
}
