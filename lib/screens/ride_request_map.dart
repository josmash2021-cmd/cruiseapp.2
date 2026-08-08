part of 'ride_request_screen.dart';

// ════════════════════════════════════════════════════════════
//  MAP — annotations, cinematic, route drawing
// ════════════════════════════════════════════════════════════

extension _RideRequestMap on _RideRequestScreenState {
  // Single source of truth for the gold route line color so the drawn
  // route and any updated/recreated route use the exact same shade.
  static const int _routeGoldColor = 0xFFF0CA3E;

  // The cinematic's final frame. Top-down and north-up, like the rider's
  // overview before it: the 55° tilt + 15° bearing used to fire here, and
  // the route overview "snapped" into a pitched close-up a second after
  // settling — the rider lost the full-route frame they had just been
  // shown. The sequence stays (pins pop, line draws, labels unroll); only
  // the orientation change is gone.
  static const double _kCinematicPitch = 0.0;
  static const double _kCinematicBearing = 0.0;

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
  Future<(Uint8List, Offset, Uint8List)?> _buildPinWithLabel({
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

    if (bytes == null) return null; // raster context gone — next pass retries
    final rawBytes = bytes.buffer.asUint8List();
    return (rawBytes, anchorOffset, rawBytes);
  }

  /// Render a standalone circular pin (no label) as raw bytes.
  Future<(Uint8List, Uint8List)?> _buildStandalonePin({
    _PinIcon icon = _PinIcon.none,
    bool isPickup = true,
  }) async {
    // Airport: clean departure icon only
    if (icon == _PinIcon.airplane) {
      final bytes = await _buildAirportIconBytes(100);
      if (bytes == null) return null; // raster context gone — retry next pass
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
  /// Null when the raster context is gone (backgrounded mid-render).
  Future<Uint8List?> _buildAirportIconBytes(double dim) async {
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
    if (byteData == null) return null; // raster context gone
    return byteData.buffer.asUint8List();
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
    // Never while the map picker is up: the latch reset + cinematic fit
    // below are the snap-back the rider sees ~1 s into a drag. Deliberately
    // NOT gated on widget.pickerMode — that flag stays true on this canvas
    // after a successful Confirm, when the route preview MUST draw.
    if (s.phase == RiderPhase.pickingLocation) return;
    // Prerequisites — bail BEFORE claiming the lock so we retry on the
    // next _onStateChange tick once the map finishes loading. Previously
    // we'd set _cinematicRunning = true and then _startCinematicSequence
    // would return immediately because _mapCtrl was null, leaving the
    // lock permanently set and blocking every future attempt.
    if (_mapCtrl == null || _polylineAnnotMgr == null) return;
    _cinematicRunning = true;
    _showPinLabels = true;
    // A route appearing is an explicit auto-frame moment, exactly like
    // entering searching (see the reset in the driver-release path) or
    // tapping recenter.
    //
    // This matters now that the per-frame writes honour `_userTookCamera`:
    // the rider almost always pans while choosing a destination, and without
    // this the flag was still set when the route arrived, so the whole
    // cinematic ran its 2.2 s producing frames that were dropped at the
    // gate. The route drew and the camera never moved.
    _userTookCamera = false;
    final pts = _capRouteEndpoints(List<LatLng>.from(s.route!.points));
    _buildRouteMarkers();
    _resetCinematic();
    _startCinematicSequence(pts);
  }

  /// Reset all cinematic animation state so sequence can replay from scratch.
  ///
  /// Intentionally does NOT touch `_cinematicRunning` — the caller (e.g.
  /// `_drawRoute`) claims that lock *before* invoking us so a second
  /// concurrent `_onStateChange` bails out. Clearing it here would undo
  /// that guard and let two cinematic sequences run in parallel.
  void _resetCinematic() {
    _cinematicDone = false;
    _hasAppliedSelectionTilt = false;
    _labelsRevealed = false;

    // Remove listeners then stop running controllers — each stop wrapped:
    // a controller disposed but not nulled throws on stop() (null check).
    _tiltAnim?.removeListener(_applyMapCamera);
    try { _tiltCtrl?.stop(); } catch (_) {}
    try { _bearingCtrl?.stop(); } catch (_) {}
    try { _pinPopCtrl?.stop(); } catch (_) {}
    try { _labelPopCtrl?.stop(); } catch (_) {}
    try { _routeDrawTicker?.stop(); } catch (_) {}

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

  /// Called when entering the searching phase. Previously this replayed
  /// the full cinematic camera sequence, which felt like a hard "reset"
  /// in the middle of the search. Now we keep whatever cinematic state
  /// is on screen and just make sure the pin labels + route are
  /// rendered, then let the fixed full-route frame at 50° pitch
  /// (_animateSearchCameraToAngle) take over.
  void _replayCinematicIfRouteAvailable() {
    final route = _ctrl.state.route;
    if (route == null || route.points.isEmpty) return;
    _showPinLabels = true;
    _buildRouteMarkers();
    // Pins and route are drawn — but the camera itself stays with the
    // rider if they already took it.
    if (_userTookCamera) return;
    // Only run a fresh cinematic if one was never played yet — otherwise
    // we'd jolt the camera back to the dropoff start frame.
    if (!_cinematicDone && !_cinematicRunning) {
      final pts = _capRouteEndpoints(List<LatLng>.from(route.points));
      _resetCinematic();
      _startCinematicSequence(pts);
    }
  }

  /// Cinematic map animation — ONE unified camera animation that
  /// controls pitch + zoom + center simultaneously so there are
  /// ZERO competing flyTo / setCamera calls.
  ///
  /// Sequence:
  ///   1. Camera starts at the DROPOFF pin, top-down (pitch 0°),
  ///      zoomed in (~16).
  ///   2. Smoothly zooms out to fit the full route above the
  ///      choose-a-ride card, STAYING top-down and north-up. (2.2 s,
  ///      easeInOutCubic) — the old 0° → 55° tilt was the "map suddenly
  ///      jumps into a pitched close-up" the rider reported.
  ///   3. Pins pop during the first 600 ms.
  ///   4. Route draws progressively during the zoom.
  ///   5. Labels unroll halfway through.
  ///   6. Sheet fades in after everything settles.
  Future<void> _startCinematicSequence(List<LatLng> pts) async {
    if (!mounted || _mapCtrl == null) return;
    // _cinematicRunning is already true — set by _drawRoute() caller.
    // Interruption token: if a cancel or the search-phase camera takes over
    // mid-flight, everything after our awaits must become a no-op.
    final gen = _cinematicGen;

    // North-up, matching the flat overview the sequence replaces. It was a
    // fixed 15° so every ride looked the same; that rotation is half of the
    // "map suddenly jumps" report, so it goes to 0 with the tilt.
    _randomBearing = 0.0;

    // ── Compute the FINAL camera we want to arrive at ──
    // This is the framed view with pitch 55°, big bottom inset for
    // the card, and the route fully visible above it.
    if (!mounted) { _cinematicRunning = false; return; }
    final mq = MediaQuery.maybeOf(context);
    // Deactivated element: same unwind as the !mounted guard above, or the
    // flag stays true and the next route never animates.
    if (mq == null) { _cinematicRunning = false; return; }
    // Measured sheet height once it has laid out — the 42% estimate
    // undershoots the real panel once a tier is picked (detail row +
    // payment row + Request Ride), and the route's tail slid under the
    // sheet on exactly the trips this sequence frames.
    final cardInset = _sheetHeightPx > 0
        ? _cameraBottomInset(mq.padding.bottom)
        : (mq.size.height * 0.42).clamp(300.0, 420.0) +
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
    bool fitOk = false;
    for (var attempt = 0; attempt < 2 && !fitOk; attempt++) {
      try {
        final cam = await _mapCtrl!.cameraForCoordinatesPadding(
          [
            mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
            mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat)),
          ],
          mapbox.CameraOptions(
              pitch: _kCinematicPitch, bearing: _randomBearing),
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
        fitOk = true;
      } catch (e) {
        debugPrint('[Cinematic] final camera compute failed '
            '(attempt ${attempt + 1}): $e');
        if (!mounted) { _cinematicRunning = false; return; }
        if (attempt == 0) {
          // The one transient cause is the style/size not being ready on a
          // fresh mount — retry once after a beat instead of falling through
          // to the hardcoded frame below.
          await Future.delayed(const Duration(milliseconds: 600));
        }
      }
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
      final mc = _mapCtrl;
      if (mc != null) {
        final cur = await mc.getCameraState();
        if (!mounted) {
          _cinematicRunning = false;
          return;
        }
        final coords = cur.center.coordinates;
        startLng = coords.lng.toDouble();
        startLat = coords.lat.toDouble();
        startPitch = cur.pitch;
        startZoom = cur.zoom;
        startBearing = cur.bearing;
      }
    } catch (_) {
      // Fallback keeps the old dropoff-centric defaults.
    }

    if (!fitOk) {
      // No reliable fit, so no flight: hold the full-route overview the
      // rider already had instead of animating to a hardcoded street zoom
      // that cuts the dropoff off the screen — the "de golpe a la vista
      // cerrada" report. Pins, route draw, labels and the end-of-sequence
      // reframe still run, so a late-ready map still gets its proper frame.
      targetZoom = startZoom;
      targetCenterLat = startLat;
      targetCenterLng = startLng;
    }

    // Small beat so the initial frame renders before animating.
    await Future.delayed(const Duration(milliseconds: 100));
    if (!mounted || _mapCtrl == null) {
      _cinematicRunning = false;
      return;
    }

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
    const endPitch = _kCinematicPitch;
    final endZoom = targetZoom;
    final endBearing = _randomBearing;

    // Bearing takes the shortest arc, not the straight line: a plain
    // start→end lerp walks the long way round whenever the incoming camera
    // sits more than ±180° from the target — that was the full 360° spin
    // the rider saw between confirming the drop-off and the route frame
    // settling (e.g. starting at 300° and sweeping ~285° instead of 45°).
    var db = endBearing - startBearing;
    while (db > 180) {
      db -= 360;
    }
    while (db < -180) {
      db += 360;
    }

    void onUnifiedTick() {
      final mc = _mapCtrl;
      if (mc == null || !mounted) return;
      final t = Curves.easeInOutCubic.transform(_tiltCtrl!.value);
      _pushCamera(mc, mapbox.CameraOptions(
        center: mapbox.Point(
          coordinates: mapbox.Position(
            startLng + (endLng - startLng) * t,
            startLat + (endLat - startLat) * t,
          ),
        ),
        pitch: startPitch + (endPitch - startPitch) * t,
        zoom: startZoom + (endZoom - startZoom) * t,
        bearing: (startBearing + db * t + 360) % 360,
      ));
    }

    _tiltCtrl!.addListener(onUnifiedTick);
    // Capture the TickerFuture ONCE so we never call forward() twice
    // (a second forward() restarts the animation from 0, doubling the
    // cinematic duration and delaying _sheetCtrl.forward() ~2x).
    final tiltFuture = _tiltCtrl!.forward(from: 0);

    // Dispose old bearing controller — no longer needed, unified handles it.
    _bearingCtrl?.dispose();
    _bearingCtrl = null;

    // ── Route draws starting at 25% of the tilt animation ──
    await Future.delayed(const Duration(milliseconds: 550));
    if (!mounted) { _cinematicRunning = false; return; }
    // SKIP route draw while the route is still the 2-point "estimated"
    // placeholder (origin → destination straight line). Drawing it would
    // put a diagonal gold line through buildings. The controller will
    // refresh state with the real road-snapped route once Directions
    // resolves; _onStateChange → _drawRoute will redraw it properly.
    // ≥3 points means Mapbox/Google/OSRM returned the polyline.
    final Future<void> routeFuture = pts.length < 3
        ? Future.value()
        : _animateGoldRoute(pts);

    // NOTE: the label reveal is NOT chained here. `routeFuture` is
    // Future.value() for the 2-point placeholder, which resolves before
    // any line exists — the labels would pop in over an empty map. It
    // lives at the end of _animateGoldRoute() instead, so it fires only
    // when a real line actually finished drawing.

    // ── Wait for BOTH tilt and route to finish ──
    await Future.wait([
      tiltFuture,
      routeFuture,
    ]);
    if (!mounted) { _cinematicRunning = false; return; }
    // Interrupted while flying (cancel, search takeover): whoever bumped
    // the token already owns the flags AND the camera — writing
    // _cinematicDone = true here was what poisoned the next ride into
    // never animating.
    if (gen != _cinematicGen) {
      _tiltCtrl?.removeListener(onUnifiedTick);
      return;
    }

    // Clean up the unified listener.
    _tiltCtrl!.removeListener(onUnifiedTick);

    _cinematicDone = true;
    _cinematicRunning = false;

    // The cinematic's target camera was computed up front. If the sheet
    // reported its real height in the meantime and it disagrees with the
    // inset that ACTUALLY framed the shot, reframe once against the real
    // panel — same orientation (preserveCamera), just a corrected inset.
    //
    // Compare against `cardInset` (what this sequence used), NOT the
    // estimate formula: when the sheet had already reported its height at
    // takeoff, cardInset was the measured value, and comparing measured vs
    // estimate re-fired a pointless reframe ~2 s after the camera had
    // settled — the rider watched the finished frame "restart" for no
    // visual gain.
    if (mounted && _sheetHeightPx > 0 && _ctrl.state.route != null) {
      final botSafe = (MediaQuery.maybeOf(context)?.padding.bottom ?? 0.0);
      // !fitOk: the takeoff compute failed, so this reframe is not a
      // correction but THE fit — always run it, whatever the inset delta.
      if (!fitOk ||
          (_cameraBottomInset(botSafe) - cardInset).abs() > 40) {
        _fitRoute(List<LatLng>.from(_ctrl.state.route!.points),
            preserveCamera: true);
      }
    }

    // Seed the floating label offsets right before they reveal so they
    // appear at the correct pin positions — the onCameraChange listener
    // keeps them glued afterwards.
    unawaited(_syncLabelOffsets());

    // If the cinematic ran on the estimated 2-point route and the REAL
    // road-snapped route has already arrived in the meantime, the
    // controller's `!_cinematicRunning` branch never fired (we WERE
    // running). Catch it now — this is the only path that guarantees
    // the polyline gets drawn when Directions resolves before the
    // cinematic's 2.2 s tilt completes.
    final latestRoute = _ctrl.state.route;
    if (mounted &&
        latestRoute != null &&
        latestRoute.points.length >= 3 &&
        _routeAnnot == null) {
      final pts = _capRouteEndpoints(List<LatLng>.from(latestRoute.points));
      _buildRouteMarkers();
      unawaited(_animateGoldRoute(pts));
    }
  }

  void _applyMapCamera() {
    final mc = _mapCtrl;
    if (mc == null || !mounted) return;
    _pushCamera(mc, mapbox.CameraOptions(
      pitch: _tiltAnim?.value,
      bearing: _bearingAnim?.value,
    ));
  }

  /// Per-frame camera write for the animation listeners (the cinematic's
  /// unified tick, [_applyMapCamera]) — the only two places that push a
  /// camera 60 times a second for seconds at a stretch.
  ///
  /// `_mapCtrl != null` says nothing about the native view. The Dart handle
  /// stays alive after the platform view is torn down, and this app
  /// multiplexes ONE Mapbox surface through MapSurfaceCoordinator, so the
  /// view can be revoked and handed to another screen while this State is
  /// still mounted — the guard passes and the call goes out anyway. Every
  /// pigeon call then rejects with PlatformException(channel-error, Unable
  /// to establish connection on channel …). It was unawaited with no
  /// handler, so it landed in the zone as an unhandled error; wrapping the
  /// call site in try/catch would not have helped either, since the
  /// rejection arrives on a later microtask, long after the sync block
  /// returned.
  ///
  /// Handling the rejection is only half of it: the animation would keep
  /// firing into the dead view for its remaining ~130 frames, each one
  /// throwing again. So on channel-error the handle is released, which is
  /// what finally makes the listeners' own `_mapCtrl == null` guard true and
  /// stops the writes at the first failure. onMapCreated re-seeds _mapCtrl
  /// when a surface comes back, so this is recoverable, not a one-way door.
  /// Coalesced, so the animation does not fight itself.
  ///
  /// This is the visible half of the bug, separate from the crash. Firing
  /// `setCamera` 60 times a second unawaited queues 130-odd pigeon calls
  /// down one channel that cannot drain that fast. Writes issued while an
  /// earlier one is still travelling are DROPPED — and per CLAUDE.md rule
  /// 25 the last one is the likeliest casualty, which is precisely the
  /// frame carrying the final pitch and bearing. What a rider sees is the
  /// move running, stalling partway, and then the camera arriving in one
  /// jump when the next unrelated write lands.
  ///
  /// Same shape as TrackingMapCar._flushCarWrite: keep only the newest
  /// pending frame, send it the moment the channel frees up, and when the
  /// animation stops the pending frame is the final one — so the end state
  /// always gets there instead of being the one that goes missing.
  /// Every animated camera move goes through here.
  ///
  /// The NaN gate alone was not enough. `flyTo` is a pigeon call and it was
  /// left unawaited with no handler, so on a surface that has been revoked it
  /// rejects with PlatformException(channel-error) straight into the zone —
  /// the exact unhandled async error `_pushCamera` was built to stop, still
  /// live on every fit path. A synchronous try/catch around it does nothing:
  /// the rejection arrives on a later microtask, long after the call returned.
  ///
  /// Releasing the handle on channel-error is what makes the callers' own
  /// `_mapCtrl == null` guards start telling the truth; onMapCreated seeds a
  /// new one when a surface comes back.
  void _safeFlyTo(mapbox.CameraOptions? cam, mapbox.MapAnimationOptions anim) {
    final mc = _mapCtrl;
    if (mc == null || !mounted) return;
    if (!_saneCam(cam)) {
      debugPrint('[Map] skipped a non-finite flyTo');
      return;
    }
    mc.flyTo(cam!, anim).catchError((Object e) {
      if (identical(_mapCtrl, mc) &&
          e is PlatformException &&
          e.code == 'channel-error') {
        _mapCtrl = null;
        debugPrint('[Map] flyTo channel gone — released stale controller');
      }
    });
  }

  void _pushCamera(mapbox.MapboxMap mc, mapbox.CameraOptions opts) {
    // The rider's hand outranks every animation. Checked here AND at flush
    // time, because those are different moments: a frame produced before
    // they grabbed the map is still in the queue when they start dragging.
    if (_userTookCamera) {
      _pendingCam = null;
      return;
    }
    _pendingCam = opts;
    if (_camWriteInFlight) return; // the in-flight write picks up the newest
    _flushCamera(mc);
  }

  /// True when every field of [cam] is something Mapbox can actually use.
  ///
  /// A NaN does not throw on our side — it crosses the pigeon channel and
  /// raises inside native: "latitude must not be NaN" from
  /// FlyToInterpolator, or NSInvalidArgumentException "Invalid number value
  /// (NaN) in JSON write" while the geometry is being serialised. Neither is
  /// catchable in Dart, which is why they show up as hard crashes spanning
  /// 1.0.3 through 1.0.9.
  ///
  /// NaN gets in the same two ways every time: a min/max fold seeded with
  /// sentinels, where every comparison against NaN is false so the sentinels
  /// survive; and arithmetic on a location that was never set. Rather than
  /// chase every producer, everything is checked at the one door it has to
  /// pass through.
  bool _saneCam(mapbox.CameraOptions? cam) {
    if (cam == null) return false;
    final c = cam.center?.coordinates;
    if (c != null) {
      final lat = c.lat.toDouble(), lng = c.lng.toDouble();
      if (!isValidLatLng(lat, lng)) return false;
      if (lat.abs() > 90 || lng.abs() > 180) return false;
    }
    for (final v in [cam.zoom, cam.pitch, cam.bearing]) {
      if (v != null && !v.isFinite) return false;
    }
    return true;
  }

  void _flushCamera(mapbox.MapboxMap mc) {
    final opts = _pendingCam;
    if (opts == null) return;
    _pendingCam = null;
    // Never hand a NaN to the channel — it crashes inside native where no
    // Dart catch can reach it. Dropping the frame costs one animation step;
    // sending it costs the app.
    if (!_saneCam(opts)) {
      _camWriteInFlight = false;
      debugPrint('[Map] dropped a non-finite camera frame');
      return;
    }
    _camWriteInFlight = true;
    // A write that never settles must not latch the gate shut.
    //
    // The flag is cleared in `then` and `catchError`, and a pigeon call to a
    // half-dead channel can do neither — that is Crashlytics #15, a
    // `TimeoutException … Future not completed` with no app frame. If that
    // happens here the flag stays true forever and `_pushCamera` silently
    // drops every later frame: no cinematic, no pitch, a camera that simply
    // stops responding for the life of the screen. Two seconds is far longer
    // than a healthy setCamera and far shorter than a rider would tolerate.
    mc.setCamera(opts).timeout(const Duration(seconds: 2)).then((_) {
      _camWriteInFlight = false;
      // A newer frame arrived mid-write — send it now rather than waiting
      // for a tick that may never come, because the animation may have
      // just ended and this is the final position.
      //
      // Unless the rider took the camera while this one was travelling.
      // That is the drag-then-snap on "choose on map": every caller checks
      // `_userTookCamera` before ASKING for a move, but the frame it
      // produced a moment earlier was still in flight, so the check had
      // already passed. It landed after their finger was down and threw
      // the map back to a top-down frame over their own location. Guarding
      // only at the call site cannot catch it; the queue has to be
      // abandoned at the moment it would be sent.
      if (_userTookCamera) {
        _pendingCam = null;
        return;
      }
      if (_pendingCam != null && identical(_mapCtrl, mc)) _flushCamera(mc);
    }).catchError((Object e) {
      _camWriteInFlight = false;
      // A transient refusal is not a reason to throw away the newest frame —
      // and on an ending animation that frame is the final position. Only a
      // dead channel makes it pointless to keep.
      if (e is PlatformException && e.code == 'channel-error') {
        _pendingCam = null;
      }
      // Only drop the controller we actually called: by the time this
      // rejection lands, onMapCreated may already have handed us a live
      // replacement, and nulling that one would leave the screen mapless.
      if (identical(_mapCtrl, mc) &&
          e is PlatformException &&
          e.code == 'channel-error') {
        _mapCtrl = null;
        debugPrint('[Map] camera channel gone — released stale controller');
      }
    });
  }

  /// Frame the FULL route top-down while dispatch searches — pitch 0,
  /// north-up, whole route above the searching-status card. Called when
  /// entering the searchingDriver phase; eases once to the frame and holds
  /// it. Never re-takes the camera from a rider who moved it themselves.
  void _animateSearchCameraToAngle(int idx) {
    // Web: the native controller is null here, which used to bail out and
    // leave the camera wherever the picker dropped it. The browser map has
    // no pitch/bearing, so "top-down full route" is just the animated fit.
    if (kIsWeb) {
      if (!mounted || _userTookCamera) return;
      final r = _ctrl.state.route;
      if (r != null && r.points.isNotEmpty) {
        // Same frame as native: top-down, north-up, 1200 ms ease, 90 px
        // top inset — undoes the cinematic's 55°/15° when the search
        // begins.
        _fitWebRoute(List<LatLng>.from(r.points),
            durationMs: 1200, pitch: 0, bearing: 0, paddingTop: 90);
      }
      return;
    }
    if (_mapCtrl == null || !mounted) return;
    // The rider panned/zoomed — their frame stays; the recenter button is
    // the way back to the full-route frame.
    if (_userTookCamera) return;

    // A rider who taps Request while the cinematic is still flying: the
    // per-frame setCamera in onUnifiedTick stomped this flyTo frame by
    // frame, and when the tilt finished the search frame restarted with a
    // stale inset — the "camera restarts" the user reported. Take the
    // camera over cleanly: bump the token (the sequence's tail becomes a
    // no-op), stop the tilt, and mark the cinematic finished.
    if (_cinematicRunning) {
      _cinematicGen++;
      _tiltCtrl?.stop();
      _cinematicRunning = false;
      _cinematicDone = true;
    }

    // Kill any in-flight search camera controller (legacy rotation).
    _searchCamCtrl?.dispose();
    _searchCamCtrl = null;

    final route = _ctrl.state.route;
    if (route == null || route.points.isEmpty) return;

    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final p in route.points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }

    final mq = MediaQuery.maybeOf(context);
    if (mq == null) return;
    // Keep the whole route visible above the searching-status card —
    // measured once the card has laid out, estimated before that.
    final bottomInset = _sheetHeightPx > 0
        ? _sheetHeightPx + 24 + 16
        : (mq.size.height * 0.38).clamp(280.0, 400.0) + mq.padding.bottom;

    _mapCtrl!
        .cameraForCoordinatesPadding(
      [
        mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
        mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat)),
      ],
      mapbox.CameraOptions(pitch: 0.0, bearing: 0.0),
      mapbox.MbxEdgeInsets(top: 90, left: 50, bottom: bottomInset, right: 50),
      null,
      null,
    )
        .then((cam) {
      // Gated like every other fit: cam.center comes straight out of
      // cameraForCoordinatesPadding and was the one write in this file
      // reaching flyTo unchecked.
      _safeFlyTo(
        mapbox.CameraOptions(
          center: cam.center,
          zoom: cam.zoom,
          pitch: 0.0,
          bearing: 0.0,
        ),
        mapbox.MapAnimationOptions(duration: 1200),
      );
    }).catchError((e) {
      debugPrint('[SearchCam] frame full route failed: $e');
    });
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
    final pickup = _pickupAnnot;
    if (pickup != null) {
      pickup.iconSize = s * 0.65;
      _pushPinUpdate(mgr, pickup);
    }
    final dropoff = _dropoffAnnot;
    if (dropoff != null) {
      dropoff.iconSize = s * 0.65;
      _pushPinUpdate(mgr, dropoff);
    }
  }

  /// Fire-and-forget iconSize write for the pop animations, which run every
  /// frame off an animation listener ([_updatePinScales],
  /// [_updateLabelScales]).
  ///
  /// The `mgr != null` check above only proves we hold *a* manager. When the
  /// style reloads, the platform view is rebuilt, or the shared Mapbox
  /// surface is handed to another screen, the manager is recreated and every
  /// annotation id we cached goes dead — the handle is non-null and stale,
  /// which is the worst possible combination. The pigeon then rejects with
  /// PlatformException(0, No manager or annotation found with manager id …).
  /// The call was unawaited and unhandled, so that rejection went straight
  /// to Crashlytics; a synchronous try/catch around it is a no-op, because
  /// an unawaited future's error never passes through the calling frame.
  ///
  /// Per CLAUDE.md rule 17 the handle is dropped inside the rejection
  /// itself, not on some later frame: the annotation no longer exists
  /// natively, so keeping the id only guarantees the next ~30 frames throw
  /// the same error. With both handles nulled the listener goes quiet, and
  /// _placeMarkersOnly / _buildRouteMarkers recreate the pins against the
  /// new manager.
  void _pushPinUpdate(
      mapbox.PointAnnotationManager mgr, mapbox.PointAnnotation annot) {
    mgr.update(annot).catchError((Object e) {
      // A channel that is merely unreachable has NOT killed the annotation.
      // Dropping the handle then would strand a live native pin with no Dart
      // reference, and the next _placeMarkers would draw a second one on top
      // of it. Only "this annotation no longer exists" means the id is dead.
      //
      // The two platforms say that completely differently, and testing for
      // the iOS shape alone meant this never fired on Android at all:
      //   iOS      PointAnnotationController.swift:8  -> code "0",
      //            message "No manager or annotation found ..."
      //   Android  PointAnnotationController.kt:107   -> Result.failure(
      //            Throwable("Annotation has not been added on the map: ..."))
      //            which reaches Dart as code "Throwable".
      // Matching on the message is what actually spans both.
      final msg = e is PlatformException
          ? '${e.code} ${e.message ?? ''}'
          : e.toString();
      final dead = msg.contains('No manager or annotation found') ||
          msg.contains('Annotation has not been added on the map');
      if (!dead) {
        debugPrint('[Pins] annotation update failed, handle kept: $e');
        return;
      }
      // Identity, not equality: if the pins were already recreated while
      // this update was in flight, the new handles must survive.
      if (identical(_pickupAnnot, annot)) _pickupAnnot = null;
      if (identical(_dropoffAnnot, annot)) _dropoffAnnot = null;
      // Rule 17(b): null the handle AND fire-and-forget the delete. Nulling
      // alone is what put two gold dots on the rider's map — the native
      // annotation outlives the handle and the next create adds a second.
      mgr.delete(annot).catchError((_) {});
      debugPrint('[Pins] annotation update rejected, handle dropped: $e');
    });
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
    final pickup = _ctrl.state.pickup;
    final dropoff = _ctrl.state.dropoff;
    // Web: same projection through GL JS — synchronous, no channel.
    // Without this branch the floating labels never had coordinates in the
    // browser and simply never appeared.
    if (kIsWeb) {
      final web = _webMapCtrl;
      if (web == null) return;
      try {
        if (pickup != null) {
          final px = web.pixelForCoordinate(pickup.lng, pickup.lat);
          if (!mounted) return;
          _setState(() => _pickupScreenOffset = px);
        }
        if (dropoff != null) {
          final px = web.pixelForCoordinate(dropoff.lng, dropoff.lat);
          if (!mounted) return;
          _setState(() => _dropoffScreenOffset = px);
        }
      } catch (e) {
        debugPrint('[Label] web _syncLabelOffsets failed: $e');
      }
      return;
    }
    final mc = _mapCtrl;
    if (mc == null) return;
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
      // NOTE: this used to also project the whole polyline into screen
      // coords (up to ~50 async pixelForCoordinate calls per camera
      // change) purely to dim the labels when the gold line passed under
      // them. That behaviour was dropped, so the projection is gone too.
    } catch (e) {
      // Mapbox throws if called before the map is ready — log so we can
      // notice if labels stop syncing unexpectedly.
      debugPrint('[Label] _syncLabelOffsets failed: $e');
    }
  }

  void _updateLabelScales() {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    final s = _labelPopAnim?.value ?? 0.65;
    // Same listener-driven, fire-and-forget write as _updatePinScales, so
    // the same dead-id rejection reached the zone from here.
    final pickup = _pickupAnnot;
    if (pickup != null) {
      pickup.iconSize = s;
      _pushPinUpdate(mgr, pickup);
    }
    final dropoff = _dropoffAnnot;
    if (dropoff != null) {
      dropoff.iconSize = s;
      _pushPinUpdate(mgr, dropoff);
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

  /// Animate the gold route line as a liquid ribbon — every frame extends
  /// the head to the exact metre along the polyline, interpolating WITHIN
  /// the current segment so there are no visible stair-steps even at
  /// high zoom. Frame-rate-independent, fire-and-forget updates.
  Future<void> _animateGoldRoute(List<LatLng> points, [Duration? duration]) async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null) {
      debugPrint('[Route] _animateGoldRoute: polyline manager not ready yet');
      return;
    }
    if (points.length < 2) {
      debugPrint('[Route] _animateGoldRoute: need ≥2 points, got ${points.length}');
      return;
    }

    // Clear old route if present
    if (_routeAnnot != null) { try { await polyMgr.delete(_routeAnnot!); } catch (_) {} _routeAnnot = null; }

    // Pre-create the annotation with the first point duplicated so the
    // ticker never awaits create() — only fire-and-forget update() calls.
    final p0 = mapbox.Position(points[0].longitude, points[0].latitude);
    final routeGeo = safeLineString(points.sublist(0, 1).followedBy(points.sublist(0, 1)));
    if (routeGeo == null) return;
    _routeAnnot = await polyMgr.create(mapbox.PolylineAnnotationOptions(
      geometry: routeGeo,
      // Warm gold — averages the web's 3-stop gradient
      // (#D4AF37 → #FFD700 → #E8C547). Solid #F0CA3E reads close to
      // the middle-weighted visual of the CSS gradient on a dark map.
      lineColor: const Color(_routeGoldColor).toARGB32(),
      lineWidth: 5.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));

    // ── Distance-based interpolation for ultra-smooth curves ──
    //
    // Precompute cumulative distance so we can advance at a constant
    // metres-per-frame rate regardless of how tightly Mapbox packs
    // points on curves. Then on every frame we interpolate WITHIN the
    // current segment (lat/lng lerp between the two surrounding points)
    // so the tip of the line lands on the exact metre, not just on the
    // next vertex — no stair-stepping even at zoom 18+.
    //
    // Duration adapts to route length. Short routes still animate over
    // 2.0 s so they never flash; long routes cap at 4.0 s.
    final totalMs = duration?.inMilliseconds ??
        (points.length * 16).clamp(2000, 4000);

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
    // Preallocated outgoing Position list — grows as the head advances
    // so we only allocate one trailing Position per frame instead of
    // rebuilding the whole coordinate array from scratch.
    final outCoords = <mapbox.Position>[p0, p0];

    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = createTicker((_) {
      if (!mounted) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
        return;
      }

      final elapsed = stopwatch.elapsedMilliseconds;
      final progress = (elapsed / totalMs).clamp(0.0, 1.0);
      // easeOutCubic: moves fast from frame 0 so the line starts
      // drawing the instant the ticker fires; eases smoothly into
      // the final metres. No "frozen start" feel.
      final eased = Curves.easeOutCubic.transform(progress);
      final targetDist = eased * totalDist;

      // Locate the segment that contains targetDist using binary
      // search — O(log n) per frame instead of O(n).
      int lo = 0;
      int hi = cumDist.length - 1;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (cumDist[mid] < targetDist) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      // lo is the first index whose cumDist >= targetDist. The head of
      // the line falls on the segment [lo-1, lo] at fraction t.
      final int fullIdx = math.max(lo, 1);
      final double prevD = cumDist[fullIdx - 1];
      final double segLen = cumDist[fullIdx] - prevD;
      final double t = segLen > 0.01
          ? ((targetDist - prevD) / segLen).clamp(0.0, 1.0)
          : 0.0;

      // Lerp lat/lng between the surrounding two anchors — this is the
      // key to smoothness. The visible tip moves at constant metres-
      // per-second, not one-vertex-per-frame.
      final a = points[fullIdx - 1];
      final b = points[fullIdx];
      final headLat = a.latitude + (b.latitude - a.latitude) * t;
      final headLng = a.longitude + (b.longitude - a.longitude) * t;

      if (_routeAnnot != null) {
        // Rebuild outCoords to exactly [p0 … points[fullIdx-1], head].
        // We keep all fully-passed vertices as-is and replace only the
        // moving tip each frame — cheap and stable.
        if (outCoords.length != fullIdx + 1) {
          outCoords
            ..clear()
            ..addAll([
              for (int i = 0; i < fullIdx; i++)
                mapbox.Position(points[i].longitude, points[i].latitude),
              mapbox.Position(headLng, headLat),
            ]);
        } else {
          outCoords[outCoords.length - 1] =
              mapbox.Position(headLng, headLat);
        }
        _routeAnnot!.geometry = mapbox.LineString(coordinates: outCoords);
        // Fire-and-forget: don't gate subsequent frames on Mapbox's
        // native bridge resolving the update — any dropped frame is
        // invisible because the next one already has the latest head.
        polyMgr.update(_routeAnnot!).catchError((_) {});
      }

      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        // Final exact snap — head at the real dropoff endpoint.
        if (_routeAnnot != null) {
          final fullCoords = [
            for (final p in points) mapbox.Position(p.longitude, p.latitude),
          ];
          _routeAnnot!.geometry =
              mapbox.LineString(coordinates: fullCoords);
          polyMgr.update(_routeAnnot!).catchError((_) {});
        }
        if (!completer.isCompleted) completer.complete();

        // ── The gold line is now fully drawn: reveal the address labels ──
        // This lives here, not in the cinematic, so EVERY path that draws
        // the route reveals them — the cinematic, the late Directions
        // redraw when the real road-snapped route arrives, and any
        // _drawRoute on a route change. _unrollLabels' own _labelsRevealed
        // guard makes repeat calls a no-op. _syncLabelOffsets first so the
        // pills animate in at the right pin positions, not a stale offset.
        if (mounted) {
          unawaited(() async {
            await _syncLabelOffsets();
            if (mounted) _unrollLabels();
          }());
        }
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
    final routeGeo = safeLineString(points);
    if (routeGeo == null) return;
    _routeAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: routeGeo,
      lineColor: const Color(_routeGoldColor).toARGB32(),
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
      final pickupPoint = safePoint(s.pickup!.lng, s.pickup!.lat);
      if (pickupPoint != null) {
        _pickupAnnot ??= await mgr.create(mapbox.PointAnnotationOptions(
          geometry: pickupPoint,
          image: _goldPinIcon!,
          iconSize: 0.85,
          iconAnchor: mapbox.IconAnchor.BOTTOM,
          iconOffset: [0, 0],
        ));
      }
      final dropoffPoint = safePoint(s.dropoff!.lng, s.dropoff!.lat);
      if (dropoffPoint != null) {
        _dropoffAnnot ??= await mgr.create(mapbox.PointAnnotationOptions(
          geometry: dropoffPoint,
          image: _goldDropoffPinIcon ?? _goldPinIcon!,
          iconSize: 0.85,
          iconAnchor: mapbox.IconAnchor.BOTTOM,
          iconOffset: [0, 0],
        ));
      }
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

    // During cinematic, pins start tiny and grow via _startPinPop(). But
    // the pop is a one-shot 500 ms window racing the pin BITMAP renders
    // (4 sequential toImage/PNG round-trips — often slower, worst on
    // Android): a marker created after the pop's last tick froze at 0.01
    // forever, and because pickup and dropoff are created by two awaited
    // IPCs in sequence, the pop could land between them — pickup popped,
    // dropoff invisible. That asymmetry is the reported "animation only
    // shows on the pickup". Compute the scale FRESH per create: mid-pop
    // markers adopt the pop's live value (its listener keeps driving
    // them), late markers land directly at the pop's final 0.65.
    double pinScale() {
      if (_cinematicDone) return 0.85;
      final pop = _pinPopCtrl;
      if (pop != null && pop.isAnimating) {
        return ((_pinPopAnim?.value ?? 0.015) * 0.65).clamp(0.01, 1.0);
      }
      return (pop?.status == AnimationStatus.completed) ? 0.65 : 0.01;
    }
    // Labels now live as Flutter overlay widgets (AnimatedMapLabel),
    // so we always draw the pin-only bitmap — the bitmap-with-label
    // variant is only kept for legacy paths that still reference it.

    // Pickup marker
    if (_pickupAnnot != null) { try { await mgr.delete(_pickupAnnot!); } catch (_) {} _pickupAnnot = null; }
    if (s.pickup != null) {
      Uint8List? bytes = _pickupPinOnly?.$1 ?? _goldPinIcon;
      final pickupPoint = safePoint(s.pickup!.lng, s.pickup!.lat);
      if (bytes != null && pickupPoint != null) {
        _pickupAnnot = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: pickupPoint,
          image: bytes,
          iconSize: pinScale(),
          iconAnchor: mapbox.IconAnchor.BOTTOM,
          iconOffset: [0, 0],
        ));
      }
    }

    // Dropoff marker
    if (_dropoffAnnot != null) { try { await mgr.delete(_dropoffAnnot!); } catch (_) {} _dropoffAnnot = null; }
    if (s.dropoff != null) {
      Uint8List? bytes = _dropoffPinOnly?.$1 ?? _goldDropoffPinIcon ?? _goldPinIcon;
      final dropoffPoint = safePoint(s.dropoff!.lng, s.dropoff!.lat);
      if (bytes != null && dropoffPoint != null) {
        _dropoffAnnot = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: dropoffPoint,
          image: bytes,
          iconSize: pinScale(),
          iconAnchor: mapbox.IconAnchor.BOTTOM,
          iconOffset: [0, 0],
        ));
      }
    }
    if (mounted) _setState(() {});
  }

  // Labels always visible — no toggle behavior
  void _togglePinLabels() {}

  /// Bottom camera inset that keeps the route framed above the sheet.
  ///
  /// Uses the sheet's MEASURED height once it has laid out; before that it
  /// falls back to the old fraction-of-screen estimate. The address bar
  /// floats above the sheet while addresses are shown, so its height goes
  /// into the inset too — otherwise the top of the route would slide under
  /// the bar on long trips.
  double _cameraBottomInset(double botSafe) {
    // 70 px of breathing room above the sheet, not 18. The route's lowest
    // pin carries a floating address label; with 18 the label sat glued to
    // the sheet's top edge (user report, 2026-08-04) instead of living
    // comfortably in the visible map area.
    if (_sheetHeightPx <= 0) {
      final screenH = (MediaQuery.maybeOf(context)?.size.height ?? 800.0);
      return (screenH * 0.35).clamp(190.0, 320.0) + botSafe + 70;
    }
    return _sheetHeightPx + _sheetScreenGap + 70;
  }

  /// The sheet reported a new height. Store it, then reframe ONCE after
  /// the panel settles — the 380 ms open/grow animation reports a size
  /// every frame, and fitting on each report made the camera bounce
  /// nonstop. Never yanks the camera away from a rider who moved it.
  void _onSheetHeightChanged(double h) {
    if (!mounted || (h - _sheetHeightPx).abs() < 12) return;
    _setState(() => _sheetHeightPx = h);
    _sheetFitDebounce?.cancel();
    _sheetFitDebounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      final s = _ctrl.state;
      if (s.route == null) return;
      // The rider dragged or zoomed — the frame is theirs now; only the
      // recenter button hands it back to us.
      if (_userTookCamera) return;
      // Searching: re-frame top-down with the card's measured height.
      if (s.phase == RiderPhase.requesting ||
          s.phase == RiderPhase.searchingDriver) {
        _animateSearchCameraToAngle(0);
        return;
      }
      if (s.phase != RiderPhase.previewRoute &&
          s.phase != RiderPhase.selectingRide) {
        return;
      }
      if (kIsWeb) {
        // Same refusals as native: never fight the cinematic mid-flight
        // (the programmatic window is exactly its duration) and never take
        // the camera back from a rider who panned away.
        if (_userTookCamera ||
            DateTime.now().isBefore(_webAutoCameraUntil)) {
          return;
        }
        // Tier picked: reframe for the taller sheet but HOLD the cinematic
        // orientation — native's _fitRoute(preserveCamera: true) flies
        // 1400 ms keeping the 55°/15°. Without these GL JS would snap the
        // bearing back to 0.
        _fitWebRoute(s.route!.points,
            durationMs: 1400,
            pitch: _kCinematicPitch,
            bearing: _kCinematicBearing);
        return;
      }
      if (_cinematicRunning || !_cinematicDone) return;
      _fitRoute(List<LatLng>.from(s.route!.points), preserveCamera: true);
    });
  }

  /// Web: fit the whole route above the sheet. No-op without the browser
  /// controller or points.
  /// [pitch]/[bearing] pass straight to GL JS so a fit can fly tilted —
  /// the cinematic frames at 55°/15° like native, the searching phase goes
  /// back to 0°/0° top-down like native. Omitted, GL JS resets bearing to 0
  /// and keeps the current pitch.
  void _fitWebRoute(List<LatLng> pts,
      {int durationMs = 1000,
      double? pitch,
      double? bearing,
      double paddingTop = 70}) {
    final web = _webMapCtrl;
    if (web == null || pts.isEmpty) return;
    final botSafe = (MediaQuery.maybeOf(context)?.padding.bottom ?? 0.0);
    // This move is ours — onCameraMove must not read it as a rider gesture.
    _webAutoCameraUntil =
        DateTime.now().add(Duration(milliseconds: durationMs + 250));
    web.fitBounds(
      [for (final p in pts) (lng: p.longitude, lat: p.latitude)],
      paddingTop: paddingTop,
      paddingLeft: 50,
      paddingBottom: _cameraBottomInset(botSafe),
      paddingRight: 50,
      durationMs: durationMs,
      pitch: pitch,
      bearing: bearing,
    );
  }

  /// Web: push the route polyline + endpoint pins to the browser map.
  /// Native draws through the cinematic instead; on web `_mapCtrl` is null
  /// and without this the map stayed empty behind the sheet.
  Future<void> _drawWebRouteOnce() async {
    final web = _webMapCtrl;
    final s = _ctrl.state;
    // Same picker rule as _drawRoute: no pins, no line, no fit while the
    // rider drags under the center pin. Phase-gated, not pickerMode-gated —
    // pickerMode is still true here after a successful Confirm.
    if (s.phase == RiderPhase.pickingLocation) return;
    if (web == null || s.route == null || s.pickup == null || s.dropoff == null) {
      return;
    }
    final pts = s.route!.points;
    if (pts.length < 2) return;
    // Identity of the route on screen: the controller notifies for tier
    // taps, surge updates and schedule changes too, and each notify lands
    // here — without this check every one re-pushed the line and re-flew
    // the camera (yanking a rider who had panned to inspect the route).
    final sig = Object.hash(pts.length, pts.first.latitude,
        pts.first.longitude, pts.last.latitude, pts.last.longitude);
    if (_webRouteDrawn) {
      if (sig == _webRouteSig && _webRouteLineDrawn) return; // nothing new
      // A NEW route (edited pickup/dropoff, or the road-snapped points
      // replacing the placeholder): the old draw timer still holds the OLD
      // points and 33 ms later would repaint them over the new line.
      _webRouteAnimTimer?.cancel();
      _webRouteSig = sig;
      if (!_webRouteLineDrawn && pts.length >= 3) {
        // The cinematic ran on the 2-point placeholder and skipped the
        // line; the real road route just landed — animate it now, mid- or
        // post-flight, same as native's end-of-cinematic catch.
        _animateWebRoute(web, pts);
        return;
      }
      if (pts.length < 3) {
        // Editing flows re-emit the 2-point estimate first. Native never
        // draws it; drop the stale line and wait for the road route.
        web.removePolyline('route');
        _webRouteLineDrawn = false;
        return;
      }
      // Re-fetched route (edited pickup/dropoff): setPolyline replaces the
      // line under the same id, so the new one redraws over the old — and
      // the pins move to the NEW endpoints with it (they used to stay put).
      web.setPolyline(
        'route',
        [for (final p in pts) (lng: p.longitude, lat: p.latitude)],
        color: '#F0CA3E',
        width: 5,
      );
      web.updateMarkerPosition('pickup', s.pickup!.lng, s.pickup!.lat);
      web.updateMarkerPosition('dropoff', s.dropoff!.lng, s.dropoff!.lat);
      // A rider who took the camera keeps it — same rule as every native
      // auto-frame.
      if (!_userTookCamera) _fitWebRoute(pts, durationMs: 500);
      return;
    }
    _webRouteSig = sig;
    _webRouteDrawn = true; // claim before the awaits so ticks don't double-add pins
    // First draw = the browser cinematic, the same sequence native runs in
    // _startCinematicSequence and in the same order:
    //   1. pins pop in (CSS twin of the 500 ms TweenSequence),
    //   2. ONE camera flight to the route frame at pitch 55° / bearing 15°
    //      over 2.2 s (GL JS fitBounds animates all axes together — the
    //      browser twin of the unified tilt controller),
    //   3. the gold line starts drawing 550 ms into the flight,
    //   4. the floating labels unroll once the line lands (wired at the
    //      end of _animateWebRoute, exactly like _animateGoldRoute).
    try {
      // The SAME golden pins Android shows (person at pickup, address-type
      // icon at dropoff), rendered by the same painter at 2x. Native's
      // final pop scale is 0.65 of the 80×73.6 logical bitmap → 52×48 CSS
      // px, tip on the coordinate (anchor bottom = IconAnchor.BOTTOM).
      final dropoffIcon = _detectDropoffType(s.dropoffLabel);
      final pins = await Future.wait([
        renderCircularPinBytes(
            icon: CircularPinIcon.person, isPickup: true, radius: 32),
        renderCircularPinBytes(
            icon: _pinIconToCircular(dropoffIcon), isPickup: false, radius: 32),
      ]);
      if (!mounted) return;
      web.addMarker('pickup', s.pickup!.lng, s.pickup!.lat,
          iconBytes: pins[0],
          popIn: true,
          widthPx: 52,
          heightPx: 48,
          anchor: 'bottom');
      web.addMarker('dropoff', s.dropoff!.lng, s.dropoff!.lat,
          iconBytes: pins[1],
          popIn: true,
          widthPx: 52,
          heightPx: 48,
          anchor: 'bottom');
    } catch (_) {}
    if (!mounted) return;
    _fitWebRoute(pts,
        durationMs: 2200,
        pitch: _kCinematicPitch,
        bearing: _kCinematicBearing,
        paddingTop: 80);
    // Route draws starting ~25% into the flight, same beat as native.
    await Future.delayed(const Duration(milliseconds: 550));
    if (!mounted) return;
    // Native rule: never draw the 2-point "estimated" placeholder — a
    // straight diagonal through buildings. The cinematic (camera + pins)
    // has already run; when the real road route lands, the refetch branch
    // sees the line was never drawn and animates it, exactly like the
    // catch at the end of _startCinematicSequence.
    if (pts.length >= 3) _animateWebRoute(web, pts);
  }

  /// Web: progressive route draw — extends the gold polyline a few points
  /// per tick with easeOutCubic timing, mirroring the native
  /// _animateGoldRoute. Simpler than native (vertex slicing, no per-metre
  /// interpolation): at route-preview zooms the steps are invisible.
  void _animateWebRoute(WebMapController web, List<LatLng> pts) {
    _webRouteAnimTimer?.cancel();
    _webRouteLineDrawn = true;
    // Same duration rule as native: ~16 ms per point, clamped 2–4 s.
    final totalMs = (pts.length * 16).clamp(2000, 4000);
    final stopwatch = Stopwatch()..start();
    // Width 5 — same as the native _animateGoldRoute line. Two identical
    // seed points, not one: a 1-coordinate LineString is invalid GeoJSON
    // that GL JS refuses to render (native seeds the same way).
    web.setPolyline('route', [
      (lng: pts[0].longitude, lat: pts[0].latitude),
      (lng: pts[0].longitude, lat: pts[0].latitude),
    ], color: '#F0CA3E', width: 5);
    _webRouteAnimTimer =
        Timer.periodic(const Duration(milliseconds: 33), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final progress =
          (stopwatch.elapsedMilliseconds / totalMs).clamp(0.0, 1.0);
      final eased = Curves.easeOutCubic.transform(progress);
      final count = 2 + (eased * (pts.length - 2)).round();
      web.setPolyline(
        'route',
        [for (final p in pts.take(count)) (lng: p.longitude, lat: p.latitude)],
        color: '#F0CA3E',
        width: 5,
      );
      if (progress >= 1.0) {
        timer.cancel();
        // Same beat as native: the floating labels unroll only once a real
        // line finished drawing (see the NOTE in _startCinematicSequence).
        unawaited(_syncLabelOffsets().then((_) {
          if (mounted) _unrollLabels();
        }));
      }
    });
  }

  void _fitRoute(List<LatLng> pts, {bool preserveCamera = false}) {
    if (pts.isEmpty || _mapCtrl == null) return;
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final botPad = (MediaQuery.maybeOf(context)?.padding.bottom ?? 0.0);
    final phase = _ctrl.state.phase;
    // Keep the route framed in the visible map area above the sheet —
    // measured once the panel has laid out, estimated before that.
    final double bottomPad;
    if (phase == RiderPhase.requesting || phase == RiderPhase.searchingDriver) {
      // Searching card: measured height + its 24px float off the edge.
      bottomPad = (_sheetHeightPx > 0 ? _sheetHeightPx + 24 : 160.0) + botPad + 16;
    } else {
      bottomPad = _cameraBottomInset(botPad);
    }
    _mapCtrl!.cameraForCoordinatesPadding(
      [mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
       mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat))],
      mapbox.CameraOptions(
        pitch: preserveCamera ? _kCinematicPitch : null,
        bearing: preserveCamera ? _randomBearing : null,
      ),
      mapbox.MbxEdgeInsets(top: 60, left: 40, bottom: bottomPad, right: 40),
      null, null,
    ).then((cam) {
      // Longer cinematic fit so the reveal of pickup → dropoff feels
      // gentle instead of a quick flick (user asked for smooth, not
      // rapid camera motion).
      _safeFlyTo(cam, mapbox.MapAnimationOptions(duration: 1400));
    }).catchError((Object _) {});
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
      mapbox.CameraOptions(pitch: _kCinematicPitch, bearing: _randomBearing),
      mapbox.MbxEdgeInsets(top: 80, left: 50, bottom: bottomInset, right: 50),
      null, null,
    ).then((cam) {
      _safeFlyTo(cam, mapbox.MapAnimationOptions(duration: 1200));
    }).catchError((Object _) {});
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
    final nav = _nav;
    if (nav == null) return;
    nav.push(
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
            _nav?.pop(); // pop tracking
            _nav?.pop(); // pop ride request → back to home
          },
        ),
      ),
    ).then((result) {
      // Reset flag whenever tracking screen is popped (including back gesture or cancel)
      _ctrl.isOnTrackingScreen = false;
      // The driver handed the trip back — glide straight back into the
      // "Looking for your driver" state (user spec 2026-08-04): same
      // trip, dispatch is already re-offering it.
      if (result == 'driver_released' && mounted) {
        _resumeSearchingAfterRelease();
      }
    });
  }

  /// Re-enter the searching phase after the assigned driver released the
  /// trip. The searching-phase handler re-arms its card, timers, cinematic
  /// and camera when it sees _searchingShowMap false; the delayed second
  /// frame covers the map surface remounting after the tracking screen's
  /// pop (its own map owned the GPU meanwhile).
  void _resumeSearchingAfterRelease() {
    if (!mounted) return;
    debugPrint('[RideRequest] Driver released — resuming searching state');
    _driverFoundVisible = false;
    _navigatingToTracking = false;
    _searchingShowMap = false;
    // Entering searching is an explicit auto-frame moment.
    _userTookCamera = false;
    _ctrl.resumeSearchingAfterDriverRelease();
    Future.delayed(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      if (_ctrl.state.phase == RiderPhase.searchingDriver) {
        _replayCinematicIfRouteAvailable();
        _animateSearchCameraToAngle(0);
      }
    });
  }


  Future<void> _applyDarkNavyGoldTheme(mapbox.MapboxMap ctrl) async {
    await MapTheme.applyNavyGold(ctrl);
    // The bottom sheet covers the lower 40-50% of the map. Mapbox's
    // native POI labels (Apple Pay, Holiday Inn, hotels, restaurants)
    // anchor to their coordinates and leak above the sheet edge. The
    // web widget's booking map never shows business POIs — hide them
    // here so the rider only sees streets + our pickup/dropoff pins.
    await MapTheme.hidePoiLayers(ctrl);
  }

  /// Re-frames the map: fits pickup+dropoff when both exist, otherwise
  /// flies to the rider. Safe to call repeatedly — it holds no state, so
  /// the button behind it stays live for as many taps as the rider wants.
  Future<void> _recenterMap() async {
    // Logged for the same hunt as _gpsMayMoveCamera: this is the other thing
    // that can fly the picker to the rider's own position, and it should only
    // ever run from a tap on the recenter button.
    debugPrint('[CamSnap] _recenterMap() — phase=${_ctrl.state.phase} '
        'pickerMode=${widget.pickerMode}');
    // The rider explicitly asked us to re-frame — hand the camera back to
    // the automatic fits.
    _userTookCamera = false;
    final s = _ctrl.state;
    // While dispatch searches, "recenter" means the top-down full-route
    // frame above the searching card.
    if (s.phase == RiderPhase.requesting ||
        s.phase == RiderPhase.searchingDriver) {
      _animateSearchCameraToAngle(0);
      return;
    }
    // If we have pickup+dropoff, fit both in view
    if (s.pickup != null && s.dropoff != null) {
      // Web has no native controller — the browser map fits its own bounds.
      if (kIsWeb) {
        final pts = s.route?.points ??
            [LatLng(s.pickup!.lat, s.pickup!.lng),
             LatLng(s.dropoff!.lat, s.dropoff!.lng)];
        // Native recenter keeps whatever orientation the camera holds; in
        // the route-preview phases that is the cinematic's 55°/15°, and
        // GL JS would silently reset the bearing to 0 without these.
        _fitWebRoute(pts,
            durationMs: 1100,
            pitch: _kCinematicPitch,
            bearing: _kCinematicBearing);
        return;
      }
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
      final botSafe = (MediaQuery.maybeOf(context)?.padding.bottom ?? 0.0);
      final bottomPad = _cameraBottomInset(botSafe);
      final cam = await _mapCtrl?.cameraForCoordinatesPadding(
        coords, mapbox.CameraOptions(),
        mapbox.MbxEdgeInsets(top: 80, left: 60, bottom: bottomPad, right: 60), null, null,
      );
      // Slower fit so the fly feels fluid instead of snappy.
      if (cam != null) {
        _safeFlyTo(cam, mapbox.MapAnimationOptions(duration: 1100));
      }
    } else if (_userLocation != null) {
      // Web: the picker phase shows this button too, and _mapCtrl is null
      // in the browser — the tap was a silent no-op while Android glided.
      if (kIsWeb) {
        _webAutoCameraUntil =
            DateTime.now().add(const Duration(milliseconds: 1150));
        _webMapCtrl?.flyTo(
          lng: _userLocation!.longitude,
          lat: _userLocation!.latitude,
          zoom: 15.5,
          durationMs: 900,
        );
        return;
      }
      // The recenter is fed straight from _userLocation, which is the most
      // likely carrier of a never-set or half-computed coordinate — exactly
      // the shape that reaches FlyToInterpolator as "latitude must not be
      // NaN". Better no recenter than a crash.
      final me = mapbox.CameraOptions(
        center: mapbox.Point(
          coordinates: mapbox.Position(
              _userLocation!.longitude, _userLocation!.latitude),
        ),
        zoom: 15.5,
      );
      if (!_saneCam(me)) return;
      _mapCtrl?.flyTo(
        me,
        // 500 ms → 900 ms so the re-center glide never feels like a snap.
        mapbox.MapAnimationOptions(duration: 900),
      ).catchError((Object _) {});
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
    if (!mounted) return;
    // On web the native controller is never created; the browser map has its
    // own. Bailing on `_mapCtrl == null` made the whole picker inert there.
    if (_mapCtrl == null && _webMapCtrl == null) return;
    final gen = ++_pickerGeocodeGen;

    // Read current camera center — that's where the fixed pin tip is.
    LatLng? snap;
    try {
      final web = _webMapCtrl;
      if (web != null) {
        final c = web.getCenter();
        snap = LatLng(c.lat, c.lng);
      } else {
        final cam = await _mapCtrl!.getCameraState();
        final c = cam.center.coordinates;
        snap = LatLng(c.lat.toDouble(), c.lng.toDouble());
      }
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
    //
    // Every early return on this path must release `_pickerConfirming` —
    // the guard at the top of _pickerConfirm keys on it, so one stuck
    // `true` disables the Confirm button for the rest of the picker's life.
    Future.delayed(const Duration(milliseconds: 1000), () async {
      void release() {
        if (mounted) _setState(() => _pickerConfirming = false);
      }
      if (!mounted) return;
      // Web has no native controller — bailing on `_mapCtrl == null` here
      // left the button spinning forever and the drop-off never committed.
      if (_mapCtrl == null && _webMapCtrl == null) {
        release();
        return;
      }
      LatLng? center;
      try {
        final web = _webMapCtrl;
        if (web != null) {
          final c = web.getCenter();
          center = LatLng(c.lat, c.lng);
        } else {
          final cam = await _mapCtrl!.getCameraState();
          final c = cam.center.coordinates;
          center = LatLng(c.lat.toDouble(), c.lng.toDouble());
        }
      } catch (_) {}
      if (!mounted) return;
      if (center == null) {
        release();
        return;
      }

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

      // Phase exits pickingLocation.
      //   - Both endpoints set: _tryFetchRoute() (triggered by
      //     setPickup/setDropoff above) now KEEPS pickingLocation —
      //     its flip was the mid-drag snap-back — so the exit below
      //     calls finishPickingLocation() explicitly.
      //   - Missing endpoint: try to auto-fill the missing leg with
      //     the user's current GPS so we stay on the same canvas
      //     (mirrors the "Choose on map" pickup flow). Only bounce
      //     back to search if GPS isn't resolved yet.
      var s = _ctrl.state;
      if (s.pickup == null && _userLocation == null) {
        // GPS may still be resolving — on web getCurrentPosition IS the
        // browser permission prompt and can take several seconds. Bouncing
        // back to search here popped the picker before the fix arrived,
        // dumping the rider on the search screen right after a valid
        // Confirm. Wait for the in-flight location init instead; only
        // bounce back if it finished (or timed out) without any fix.
        final pending = _locationReadyFuture;
        if (pending != null) {
          await pending.timeout(
            const Duration(seconds: 12),
            onTimeout: () {},
          );
          if (!mounted) return;
          s = _ctrl.state;
        }
      }
      // Any known fix beats bouncing the rider out of the picker: live GPS
      // first, then the fix the PreloadService cached at app boot. The
      // bounce below is the worst outcome — a valid Confirm answered with
      // a pop back to search — so it is strictly the last resort.
      LatLng? pickupFix = _userLocation;
      if (s.pickup == null && pickupFix == null) {
        final lat = LocalCache.get<double>('last_driver_lat');
        final lng = LocalCache.get<double>('last_driver_lng');
        if (lat != null && lng != null) {
          pickupFix = LatLng(lat, lng);
          debugPrint('[Picker] pickup from cached boot fix $lat,$lng');
        }
      }
      if (s.pickup == null && pickupFix != null) {
        final curLabel = _currentAddress.isNotEmpty
            ? _currentAddress
            : 'Current location';
        _ctrl.setPickup(
          PlaceDetails(
            address: curLabel,
            lat: pickupFix.latitude,
            lng: pickupFix.longitude,
          ),
          curLabel,
        );
        s = _ctrl.state;
      }
      if (s.pickup == null || s.dropoff == null) {
        _ctrl.startLocationSelection();
        final popNav = _nav;
        if (popNav != null && popNav.canPop()) {
          popNav.pop();
          return;
        }
      } else {
        // Both endpoints committed (directly, or via the GPS/cached-fix
        // auto-fill above) — leave the picker for the route preview.
        _ctrl.finishPickingLocation();
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
    if (map == null) {
      // Web: same ripple through the browser controller's circles.
      _webPickerStartRipple();
      return;
    }
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

  /// Web twin of [_pickerStartRipple]: the native code drives style-layer
  /// circle properties directly; the browser controller only exposes
  /// `setCircle`, which now re-pushes radius/opacity on every call — enough
  /// to run the same three gold waves at the pin tip (the camera center).
  void _webPickerStartRipple() {
    final web = _webMapCtrl;
    if (web == null) return;
    final c = web.getCenter();
    for (int i = 0; i < _pickerRippleWaveCount; i++) {
      web.setCircle('picker-ripple-$i', c.lng, c.lat,
          radiusPx: 0, color: '#E8C547', opacity: 0);
    }
    _pickerRippleElapsed = 0.0;
    _pickerRippleTicker?.dispose();
    _pickerRippleTicker = createTicker((elapsed) {
      _pickerRippleElapsed = elapsed.inMilliseconds.toDouble();
      if (_pickerRippleElapsed > _pickerRippleDurationMs) {
        _pickerRippleTicker?.stop();
        _webPickerCleanupRipple();
        return;
      }
      _webPickerUpdateRipple();
    })..start();
  }

  void _webPickerUpdateRipple() {
    final web = _webMapCtrl;
    if (web == null) return;
    final c = web.getCenter();
    for (int i = 0; i < _pickerRippleWaveCount; i++) {
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
      web.setCircle('picker-ripple-$i', c.lng, c.lat,
          radiusPx: radius, color: '#E8C547', opacity: opacity * 0.25);
    }
  }

  void _webPickerCleanupRipple() {
    final web = _webMapCtrl;
    if (web == null) return;
    for (int i = 0; i < _pickerRippleWaveCount; i++) {
      web.removeCircle('picker-ripple-$i');
    }
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
