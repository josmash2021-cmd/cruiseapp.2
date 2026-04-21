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
    if (_cinematicRunning) return;
    // Claim the lock BEFORE resetting so a second _onStateChange that
    // fires between _resetCinematic() and _startCinematicSequence()
    // sees _cinematicRunning == true and bails. This was the cause of
    // the "double tilt" the user saw — two sequences ran in parallel.
    _cinematicRunning = true;
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

    // NOTE: we no longer force the camera to pitch:0/bearing:0 here —
    // _startCinematicSequence now reads the map's ACTUAL current camera
    // and interpolates from there, which keeps the handoff from the
    // map picker smooth (no snap to top-down before the tilt starts).

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

  /// Cinematic map animation — ONE unified camera animation that
  /// controls pitch + zoom + center simultaneously so there are
  /// ZERO competing flyTo / setCamera calls.
  ///
  /// Sequence the user asked for:
  ///   1. Camera starts at the DROPOFF pin, top-down (pitch 0°),
  ///      zoomed in (~16).
  ///   2. Slowly tilts 0° → 55° while zooming out to fit the full
  ///      route above the choose-a-ride card. (2.2 s, easeInOutCubic)
  ///   3. Pins pop during the first 600 ms.
  ///   4. Route draws progressively during the tilt/zoom.
  ///   5. Labels unroll halfway through.
  ///   6. Sheet fades in after everything settles.
  Future<void> _startCinematicSequence(List<LatLng> pts) async {
    if (!mounted || _mapCtrl == null) return;
    // _cinematicRunning is already true — set by _drawRoute() caller.

    // Fixed 15° bearing — matches the Shopify widget's static camera
    // angle during step 3. Previously randomized ±5–12°, but the web is
    // intentionally consistent so every ride looks the same.
    _randomBearing = 15.0;

    // ── Compute the FINAL camera we want to arrive at ──
    // This is the framed view with pitch 55°, big bottom inset for
    // the card, and the route fully visible above it.
    if (!mounted) { _cinematicRunning = false; return; }
    final mq = MediaQuery.of(context);
    final cardInset = (mq.size.height * 0.42).clamp(300.0, 420.0) +
        mq.padding.bottom + 24;
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    // Compute the target camera WITHOUT setting it — avoids the flash
    // where the map jumps to the final view then snaps back to start.
    double targetZoom = 14.0;
    double targetCenterLat = (minLat + maxLat) / 2;
    double targetCenterLng = (minLng + maxLng) / 2;
    try {
      final cam = await _mapCtrl!.cameraForCoordinatesPadding(
        [
          mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
          mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat)),
        ],
        mapbox.CameraOptions(pitch: 55.0, bearing: _randomBearing),
        mapbox.MbxEdgeInsets(top: 80, left: 50, bottom: cardInset, right: 50),
        null,
        null,
      );
      // Read values directly from CameraOptions — NO setCamera round-trip.
      targetZoom = cam.zoom ?? 14.0;
      if (cam.center != null) {
        targetCenterLat = cam.center!.coordinates.lat.toDouble();
        targetCenterLng = cam.center!.coordinates.lng.toDouble();
      }
    } catch (e) {
      debugPrint('[Cinematic] final camera compute failed: $e');
    }
    if (!mounted) { _cinematicRunning = false; return; }

    // ── Read the map's CURRENT camera as the animation start ──
    // When we arrive here from the map-picker handoff the camera is
    // already centered on the drop-off pin at the picker's zoom/pitch,
    // so we use that as the starting frame and interpolate smoothly
    // to the final route-framed view. No setCamera reset — no flash.
    final dropoff = pts.last;
    double startLat = dropoff.latitude;
    double startLng = dropoff.longitude;
    double startPitch = 0.0;
    double startZoom = 16.0;
    double startBearing = 0.0;
    try {
      final cur = await _mapCtrl!.getCameraState();
      final coords = cur.center.coordinates;
      startLng = coords.lng.toDouble();
      startLat = coords.lat.toDouble();
      startPitch = cur.pitch;
      startZoom = cur.zoom;
      startBearing = cur.bearing;
    } catch (_) {
      // Fallback keeps the old dropoff-centric defaults.
    }

    // Small beat so the initial frame renders before animating.
    await Future.delayed(const Duration(milliseconds: 100));
    if (!mounted) { _cinematicRunning = false; return; }

    // ── Pin pop (concurrent) ──
    _startPinPop();

    // ── UNIFIED tilt + zoom + center animation ──
    // One controller drives ALL camera axes so nothing fights.
    _tiltAnim?.removeListener(_applyMapCamera);
    _tiltCtrl?.dispose();
    _tiltCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );

    final endLat = targetCenterLat;
    final endLng = targetCenterLng;
    const endPitch = 55.0;
    final endZoom = targetZoom;
    final endBearing = _randomBearing;

    void onUnifiedTick() {
      if (_mapCtrl == null || !mounted) return;
      final t = Curves.easeInOutCubic.transform(_tiltCtrl!.value);
      _mapCtrl!.setCamera(mapbox.CameraOptions(
        center: mapbox.Point(
          coordinates: mapbox.Position(
            startLng + (endLng - startLng) * t,
            startLat + (endLat - startLat) * t,
          ),
        ),
        pitch: startPitch + (endPitch - startPitch) * t,
        zoom: startZoom + (endZoom - startZoom) * t,
        bearing: startBearing + (endBearing - startBearing) * t,
      ));
    }

    _tiltCtrl!.addListener(onUnifiedTick);
    _tiltCtrl!.forward(from: 0);

    // Dispose old bearing controller — no longer needed, unified handles it.
    _bearingCtrl?.dispose();
    _bearingCtrl = null;

    // ── Labels fade in near the END of the route draw (~80%) ──
    // so the rider sees the route almost complete, then the pickup
    // and dropoff address labels appear smoothly next to their pins.
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted) _unrollLabels();
    });

    // ── Route draws starting at 25% of the tilt animation ──
    await Future.delayed(const Duration(milliseconds: 550));
    if (!mounted) { _cinematicRunning = false; return; }
    // Fire route draw concurrently — don't await, let it overlap with tilt.
    final routeFuture = _animateGoldRoute(pts);

    // ── Wait for BOTH tilt and route to finish ──
    await Future.wait([
      _tiltCtrl!.forward(),
      routeFuture,
    ]);
    if (!mounted) { _cinematicRunning = false; return; }

    // Clean up the unified listener.
    _tiltCtrl!.removeListener(onUnifiedTick);

    _cinematicDone = true;
    _cinematicRunning = false;

    // Seed the floating label offsets right before they reveal so they
    // appear at the correct pin positions — the onCameraChange listener
    // keeps them glued afterwards.
    unawaited(_syncLabelOffsets());

    // 7. Beat + sheet fade in
    await Future.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;
    if (_sheetCtrl.status == AnimationStatus.dismissed) {
      _sheetCtrl.forward();
    }
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

  /// Trigger the animated overlay labels (pickup at 50 ms, dropoff at
  /// 300 ms) once the cinematic finishes. Matches the Shopify widget's
  /// staggered reveal sequence for .vipRide__mapLabel.
  void _unrollLabels() {
    if (_labelsRevealed) return;
    _labelsRevealed = true;

    // Pickup first — matches web's 50 ms setTimeout.
    Future.delayed(const Duration(milliseconds: 50), () {
      if (!mounted) return;
      _setState(() => _pickupLabelRevealed = true);
    });
    // Dropoff shortly after — matches web's 300 ms setTimeout.
    Future.delayed(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _setState(() => _dropoffLabelRevealed = true);
    });

    // Keep pins at their final display size (no label-bitmap swap now;
    // labels live as overlay widgets positioned via pixelForCoordinate).
    _labelPopCtrl?.dispose();
    _labelPopCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _labelPopAnim = Tween<double>(begin: 0.65, end: 0.65).animate(_labelPopCtrl!);
    _labelPopAnim!.addListener(_updateLabelScales);
    _labelPopCtrl!.forward(from: 0);
  }

  /// Reproject pickup/dropoff pin positions to screen pixels so the
  /// overlay labels follow the map while it tilts, pans or zooms.
  /// Called on every camera change event and at the end of the cinematic.
  Future<void> _syncLabelOffsets() async {
    final mc = _mapCtrl;
    if (mc == null) return;
    final pickup = _ctrl.state.pickup;
    final dropoff = _ctrl.state.dropoff;
    try {
      if (pickup != null) {
        final px = await mc.pixelForCoordinate(mapbox.Point(
          coordinates: mapbox.Position(pickup.lng, pickup.lat),
        ));
        if (!mounted) return;
        _setState(() => _pickupScreenOffset =
            Offset(px.x.toDouble(), px.y.toDouble()));
      }
      if (dropoff != null) {
        final px = await mc.pixelForCoordinate(mapbox.Point(
          coordinates: mapbox.Position(dropoff.lng, dropoff.lat),
        ));
        if (!mounted) return;
        _setState(() => _dropoffScreenOffset =
            Offset(px.x.toDouble(), px.y.toDouble()));
      }
    } catch (_) {
      // Mapbox throws if called before the map is ready — silently ignore.
    }
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
      // Warm gold — averages the web's 3-stop gradient
      // (#D4AF37 → #FFD700 → #E8C547). Solid #F0CA3E reads close to
      // the middle-weighted visual of the CSS gradient on a dark map.
      lineColor: const Color(0xFFF0CA3E).toARGB32(),
      lineWidth: 5.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));

    // ── Distance-based interpolation for ultra-smooth curves ──
    //
    // Instead of advancing by point count (which produces uneven speed
    // on curves where Mapbox packs many short segments), we precompute
    // the cumulative distance along the route and advance at constant
    // metres-per-frame. The line never jumps or stutters, even on tight
    // curves and near the endpoints.
    //
    // Duration adapts to route length. Short routes (few points)
    // still get a visible draw over 2.0 s so they never flash.
    // Long routes cap at 4.0 s so the user doesn't wait forever.
    final totalMs = duration?.inMilliseconds ??
        (points.length * 16).clamp(2000, 4000);

    // Pre-compute cumulative distances (meters along the polyline).
    final cumDist = <double>[0.0];
    for (int i = 1; i < points.length; i++) {
      final dlat = (points[i].latitude - points[i - 1].latitude) * 111320;
      final dlng = (points[i].longitude - points[i - 1].longitude) *
          111320 *
          math.cos(points[i].latitude * math.pi / 180);
      cumDist.add(cumDist.last + math.sqrt(dlat * dlat + dlng * dlng));
    }
    final totalDist = cumDist.last;

    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    double lastDistDrawn = 0;
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
      // easeOutCubic: starts drawing IMMEDIATELY (fast at the start)
      // and decelerates smoothly at the end. This fixes short routes
      // where easeInOutCubic's slow start made the line appear frozen
      // for the first 15% of the animation.
      final eased = Curves.easeOutCubic.transform(progress);
      final targetDist = eased * totalDist;

      // Advance threshold scales with total distance: 1m for short
      // routes (<500m), up to 5m for long routes. Prevents IPC
      // thrashing while keeping every curve segment smooth.
      final advanceThreshold = (totalDist * 0.005).clamp(1.0, 5.0);
      if ((targetDist - lastDistDrawn).abs() < advanceThreshold && progress < 1.0) return;
      lastDistDrawn = targetDist;

      // Find the point index where cumDist >= targetDist
      int idx = 2;
      for (int i = 1; i < cumDist.length; i++) {
        if (cumDist[i] >= targetDist) { idx = i + 1; break; }
        idx = i + 1;
      }
      idx = idx.clamp(2, points.length);

      if (_routeAnnot != null) {
        final subset = points.sublist(0, idx);
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
      labelOnLeft: true, // label on LEFT of pickup pin
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

    // During cinematic, pins start tiny and grow via _startPinPop().
    final scale = (!_cinematicDone || (_pinPopCtrl?.isAnimating ?? false)) ? 0.01 : 0.85;
    // Labels now live as Flutter overlay widgets (AnimatedMapLabel),
    // so we always draw the pin-only bitmap — the bitmap-with-label
    // variant is only kept for legacy paths that still reference it.

    // Pickup marker
    if (_pickupAnnot != null) { try { await mgr.delete(_pickupAnnot!); } catch (_) {} _pickupAnnot = null; }
    if (s.pickup != null) {
      Uint8List? bytes = _pickupPinOnly?.$1 ?? _goldPinIcon;
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
      Uint8List? bytes = _dropoffPinOnly?.$1 ?? _goldDropoffPinIcon ?? _goldPinIcon;
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
      // Longer cinematic fit so the reveal of pickup → dropoff feels
      // gentle instead of a quick flick (user asked for smooth, not
      // rapid camera motion).
      _mapCtrl?.flyTo(cam, mapbox.MapAnimationOptions(duration: 1400));
    });
  }

  /// Like [_fitRoute] but with an EXPLICIT bottom inset (in pixels)
  /// so the cinematic's final fit ALWAYS frames the route above the
  /// choose-a-ride card regardless of device size.
  void _fitRouteWithInset(List<LatLng> pts, {required double bottomInset}) {
    if (pts.isEmpty || _mapCtrl == null) return;
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    _mapCtrl!.cameraForCoordinatesPadding(
      [mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
       mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat))],
      mapbox.CameraOptions(pitch: 55.0, bearing: _randomBearing),
      mapbox.MbxEdgeInsets(top: 80, left: 50, bottom: bottomInset, right: 50),
      null, null,
    ).then((cam) {
      _mapCtrl?.flyTo(cam, mapbox.MapAnimationOptions(duration: 1200));
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
    // Hide the "Driver Found" overlay now that the tracking screen is about to slide in
    if (_driverFoundVisible) {
      _setState(() => _driverFoundVisible = false);
    }
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
      // Slower fit so the fly feels fluid instead of snappy.
      if (cam != null) _mapCtrl?.flyTo(cam, mapbox.MapAnimationOptions(duration: 1100));
    } else if (_userLocation != null) {
      _mapCtrl?.flyTo(
        mapbox.CameraOptions(center: mapbox.Point(coordinates: mapbox.Position(_userLocation!.longitude, _userLocation!.latitude)), zoom: 15.5),
        // 500 ms → 900 ms so the re-center glide never feels like a snap.
        mapbox.MapAnimationOptions(duration: 900),
      );
    }
  }

  // ═════════════════════════════════════════════════════════════════
  //  IN-PLACE MAP PICKER (RiderPhase.pickingLocation)
  //  Ported from map_picker_screen.dart so the same Mapbox canvas is
  //  reused for picker → confirm → route preview without re-mounting.
  // ═════════════════════════════════════════════════════════════════

  void _pickerScheduleGeocode() {
    _pickerDebounce?.cancel();
    _pickerDebounce = Timer(const Duration(milliseconds: 500), _pickerOnCameraIdle);
  }

  Future<void> _pickerOnCameraIdle() async {
    _pickerDebounce?.cancel();
    if (!mounted || _mapCtrl == null) return;
    final gen = ++_pickerGeocodeGen;

    // Read current camera center — that's where the fixed pin tip is.
    LatLng? snap;
    try {
      final cam = await _mapCtrl!.getCameraState();
      final c = cam.center.coordinates;
      snap = LatLng(c.lat.toDouble(), c.lng.toDouble());
    } catch (_) {}
    if (snap == null || !mounted || gen != _pickerGeocodeGen) return;

    if (_pickerAddressIsPlaceholder || _pickerGeocodeFailed) {
      _setState(() {
        _pickerLoading = true;
        _pickerGeocodeFailed = false;
      });
    }

    String? addr;
    for (int attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future.delayed(const Duration(milliseconds: 800));
      }
      if (!mounted || gen != _pickerGeocodeGen) return;
      try {
        addr = await _pickerPlaces.reverseGeocode(
          lat: snap.latitude,
          lng: snap.longitude,
        );
        if (addr != null && addr.isNotEmpty) break;
      } catch (_) {}
    }
    if (!mounted || gen != _pickerGeocodeGen) return;
    _setState(() {
      if (addr != null && addr.isNotEmpty) {
        _pickerAddress = addr;
        _pickerAddressIsPlaceholder = false;
        _pickerGeocodeFailed = false;
      } else {
        _pickerAddressIsPlaceholder = true;
        _pickerGeocodeFailed = true;
      }
      _pickerLoading = false;
    });
  }

  /// Picker confirm button — plays the pin drop bounce + native map
  /// ripple, then internally transitions to the route-preview phase
  /// WITHOUT re-mounting the map.
  Future<void> _pickerConfirm() async {
    if (_pickerAddressIsPlaceholder || _pickerAddress.isEmpty || _pickerConfirming) {
      return;
    }
    _setState(() => _pickerConfirming = true);

    // 1. Drop-bounce on the center pin.
    _pickerAnchorCtrl?.dispose();
    _pickerAnchorCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _pickerAnchorAnim = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 0.0, end: -18.0).chain(CurveTween(curve: Curves.easeOut)),
          weight: 25),
      TweenSequenceItem(
          tween: Tween(begin: -18.0, end: 4.0).chain(CurveTween(curve: Curves.easeIn)),
          weight: 40),
      TweenSequenceItem(
          tween: Tween(begin: 4.0, end: -2.0).chain(CurveTween(curve: Curves.easeOut)),
          weight: 20),
      TweenSequenceItem(
          tween: Tween(begin: -2.0, end: 0.0).chain(CurveTween(curve: Curves.easeInOut)),
          weight: 15),
    ]).animate(_pickerAnchorCtrl!);
    _pickerAnchorCtrl!.addListener(() {
      _setState(() {});
    });
    _pickerAnchorCtrl!.forward(from: 0);

    // 2. Native map ripple at the pin tip.
    Future.delayed(const Duration(milliseconds: 260), () {
      if (!mounted) return;
      _pickerStartRipple();
    });

    // 3. After the settle, read the camera + commit the picked place.
    Future.delayed(const Duration(milliseconds: 1000), () async {
      if (!mounted || _mapCtrl == null) return;
      LatLng? center;
      try {
        final cam = await _mapCtrl!.getCameraState();
        final c = cam.center.coordinates;
        center = LatLng(c.lat.toDouble(), c.lng.toDouble());
      } catch (_) {}
      if (!mounted || center == null) return;

      final place = PlaceDetails(
        address: _pickerAddress,
        lat: center.latitude,
        lng: center.longitude,
      );

      if (_pickerIsPickup) {
        _ctrl.setPickup(place, _pickerAddress);
      } else {
        _ctrl.setDropoff(place, _pickerAddress);
      }

      // Phase exits pickingLocation — setPickup/setDropoff will push the
      // controller into previewRoute once both endpoints are known. If
      // only one is set so far, we bounce back to idle so the "Where to?"
      // pill can be tapped for the other leg.
      final s = _ctrl.state;
      if (s.pickup != null && s.dropoff != null) {
        // previewRoute is triggered by setDropoff's _tryFetchRoute chain.
      } else {
        _ctrl.startLocationSelection();
      }

      if (mounted) {
        _setState(() {
          _pickerConfirming = false;
        });
      }
    });
  }

  Future<void> _pickerStartRipple() async {
    final map = _mapCtrl;
    if (map == null) return;
    LatLng center;
    try {
      final cam = await map.getCameraState();
      final c = cam.center.coordinates;
      center = LatLng(c.lat.toDouble(), c.lng.toDouble());
    } catch (_) {
      return;
    }
    final geojson = jsonEncode({
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [center.longitude, center.latitude],
          },
          'properties': {},
        }
      ],
    });
    try {
      await map.style.addSource(
          mapbox.GeoJsonSource(id: 'picker-ripple-src', data: geojson));
    } catch (_) {}
    for (int i = 0; i < _pickerRippleWaveCount; i++) {
      try {
        await map.style.addLayer(mapbox.CircleLayer(
          id: 'picker-ripple-wave-$i',
          sourceId: 'picker-ripple-src',
          circleRadius: 0.0,
          circleColor: 0xFFD4A843,
          circleOpacity: 0.0,
          circleStrokeWidth: 2.5,
          circleStrokeColor: 0xFFE8C547,
          circleStrokeOpacity: 0.0,
        ));
      } catch (_) {}
    }
    _pickerRippleElapsed = 0.0;
    _pickerRippleTicker?.dispose();
    _pickerRippleTicker = createTicker((elapsed) {
      _pickerRippleElapsed = elapsed.inMilliseconds.toDouble();
      if (_pickerRippleElapsed > _pickerRippleDurationMs) {
        _pickerRippleTicker?.stop();
        _pickerCleanupRipple();
        return;
      }
      _pickerUpdateRippleLayers();
    })..start();
  }

  void _pickerUpdateRippleLayers() {
    final map = _mapCtrl;
    if (map == null) return;
    for (int i = 0; i < _pickerRippleWaveCount; i++) {
      final layerId = 'picker-ripple-wave-$i';
      final waveOffset = i * 150.0;
      final waveTime = (_pickerRippleElapsed - waveOffset)
          .clamp(0.0, _pickerRippleDurationMs - waveOffset);
      final progress = (waveTime / (_pickerRippleDurationMs - waveOffset))
          .clamp(0.0, 1.0);
      if (progress <= 0) continue;
      final eased = 1.0 - (1.0 - progress) * (1.0 - progress);
      final maxRadius = 80.0 + (i * 30.0);
      final radius = maxRadius * eased;
      final opacity = progress < 0.15
          ? (progress / 0.15) * 0.35
          : 0.35 * (1.0 - ((progress - 0.15) / 0.85));
      final fillOpacity = opacity * 0.25;
      final strokeOpacity = opacity;
      final strokeWidth = (3.0 * (1.0 - eased * 0.5)).clamp(0.5, 3.0);
      map.style.setStyleLayerProperty(layerId, 'circle-radius', radius);
      map.style.setStyleLayerProperty(layerId, 'circle-opacity', fillOpacity);
      map.style
          .setStyleLayerProperty(layerId, 'circle-stroke-opacity', strokeOpacity);
      map.style.setStyleLayerProperty(layerId, 'circle-stroke-width', strokeWidth);
    }
  }

  Future<void> _pickerCleanupRipple() async {
    final map = _mapCtrl;
    if (map == null) return;
    for (int i = 0; i < _pickerRippleWaveCount; i++) {
      try {
        await map.style.removeStyleLayer('picker-ripple-wave-$i');
      } catch (_) {}
    }
    try {
      await map.style.removeStyleSource('picker-ripple-src');
    } catch (_) {}
  }
}
