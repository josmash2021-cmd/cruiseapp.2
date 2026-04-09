part of 'driver_online_screen.dart';

// ══════════════════════════════════════════════════════════════
//  CONTROLLER — boot, GPS, polling, offers, navigation, trips
// ══════════════════════════════════════════════════════════════

extension _DriverOnlineController on _DriverOnlineScreenState {

  String _normalizePhotoUrl(dynamic rawUrl) {
    final raw = (rawUrl ?? '').toString().replaceAll('"', '').trim();
    if (raw.isEmpty) return '';
    // Filter Python/JS sentinel strings that backend may send
    if (raw == 'null' || raw == 'None' || raw == 'undefined' || raw == 'none') return '';
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    if (raw.startsWith('/')) return '${ApiService.publicBaseUrl}$raw';
    return '${ApiService.publicBaseUrl}/$raw';
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  BOOT
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Future<void> _boot() async {
    // Get driver ID — single fast attempt, retry later if needed
    try {
      final id = await ApiService.getCurrentUserId();
      if (id != null) {
        _driverId = id;
        debugPrint('✅ Got driverId=$_driverId');
      }
    } catch (e) {
      debugPrint('⚠️ getCurrentUserId failed: $e');
    }

    // Start ALL non-blocking tasks after a short delay so the
    // page transition animation + online sound don't compete
    // for the main-thread platform-channel dispatcher.
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    _startClock();
    _startPolling();
    _startPosStream();
    _loadAllEarnings();
    _startEarningsRefresh();
    _startScheduledPoll();
    unawaited(_locate());

    // Verification + go-online in background — don't block the UI.
    // Driver already passed the home-screen gate (_ensureVerified +
    // _checkVehicleDocStatus) so this is a background safety net.
    unawaited(_verifyAndGoOnline());

    // Build vehicle icons well after the transition settles (700ms)
    // to avoid jank during the 400ms fade+scale entrance animation.
    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted) _buildVehicleIcons();
    });

    // Pre-cache map tiles in background (fire-and-forget)
    if (_pos != null) {
      MapCacheService().precacheArea(
        regionId: 'driver_area_${_driverId ?? 0}',
        lat: _pos!.latitude,
        lng: _pos!.longitude,
        minZoom: 10,
        maxZoom: 16,
        radiusKm: 5.0,
      );
    }
  }

  /// Background verification + go-online — never blocks boot.
  Future<void> _verifyAndGoOnline() async {
    // Retry driver ID if first attempt failed
    if (_driverId == null) {
      for (int attempt = 1; attempt <= 2; attempt++) {
        await Future.delayed(const Duration(milliseconds: 500));
        try {
          final id = await ApiService.getCurrentUserId();
          if (id != null) {
            _driverId = id;
            debugPrint('✅ Got driverId=$_driverId on retry $attempt');
            // Reconnect SSE now that we have an ID
            _connectSse();
            _startPosStream();
            break;
          }
        } catch (_) {}
      }
    }
    await _verifyDriverApproval();
    _goOnlineBackend();
  }

  /// Start a periodic timer to refresh earnings every 45 seconds.
  void _startEarningsRefresh() {
    _earningsRefreshTimer?.cancel();
    _earningsRefreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      _loadAllEarnings();
    });
  }

  /// Save current earnings snapshot to SharedPreferences for instant load next time.
  Future<void> _cacheEarnings() async {
    try {
      final prefs = (PrefsCache.instanceSync ?? await PrefsCache.instance);
      // Use same key as driver_home_screen for shared cache
      prefs.setDouble('driver_cached_earnings', _earnings);
      prefs.setDouble('driver_online_weekly', _weeklyEarnings);
      prefs.setDouble('driver_online_last_trip', _lastTripEarnings);
    } catch (_) {}
  }

  Future<void> _loadAllEarnings() async {
    // ── Instant: load from SharedPreferences cache first (single setState) ──
    try {
      final prefs = (PrefsCache.instanceSync ?? await PrefsCache.instance);
      final cachedToday = prefs.getDouble('driver_cached_earnings');
      final cachedWeekly = prefs.getDouble('driver_online_weekly');
      final cachedLastTrip = prefs.getDouble('driver_online_last_trip');
      bool changed = false;
      double newEarnings = _earnings;
      double newWeekly = _weeklyEarnings;
      double newLastTrip = _lastTripEarnings;
      if (_earnings == 0 && cachedToday != null && cachedToday > 0) {
        newEarnings = cachedToday; changed = true;
      }
      if (_weeklyEarnings == 0 && cachedWeekly != null && cachedWeekly > 0) {
        newWeekly = cachedWeekly; changed = true;
      }
      if (_lastTripEarnings == 0 && cachedLastTrip != null && cachedLastTrip > 0) {
        newLastTrip = cachedLastTrip; changed = true;
      }
      if (mounted && changed) {
        _setState(() {
          _prevEarnings = _earnings;
          _earnings = newEarnings;
          _prevWeeklyEarnings = _weeklyEarnings;
          _weeklyEarnings = newWeekly;
          _prevLastTripEarnings = _lastTripEarnings;
          _lastTripEarnings = newLastTrip;
        });
      }
    } catch (_) {}

    // ── Background: fetch fresh data from API (single setState) ──
    try {
      final results = await Future.wait([
        ApiService.getDriverEarnings(period: 'week'),
        ApiService.getDriverEarnings(period: 'today'),
      ]);
      if (!mounted) return;

      final weekData = results[0];
      final todayData = results[1];
      final weekTotal = (weekData['total'] as num?)?.toDouble() ?? 0;
      final todayTotal = (todayData['total'] as num?)?.toDouble() ?? 0;
      final txns = todayData['transactions'] as List<dynamic>?;
      final lastFare = (txns != null && txns.isNotEmpty)
          ? (txns.first['fare'] as num?)?.toDouble() ?? 0.0
          : 0.0;

      bool changed = false;
      if (weekTotal != _weeklyEarnings) changed = true;
      if (todayTotal > _earnings) changed = true;
      if (_lastTripEarnings == 0 && lastFare > 0) changed = true;

      if (changed) {
        _setState(() {
          if (weekTotal != _weeklyEarnings) {
            _prevWeeklyEarnings = _weeklyEarnings;
            _weeklyEarnings = weekTotal;
          }
          if (todayTotal > _earnings) {
            _prevEarnings = _earnings;
            _earnings = todayTotal;
          }
          if (_lastTripEarnings == 0 && lastFare > 0) {
            _prevLastTripEarnings = _lastTripEarnings;
            _lastTripEarnings = lastFare;
          }
        });
      }
      // Save fresh data to cache
      _cacheEarnings();
    } catch (_) {}
  }

  Future<void> _locate() async {
    // Use pre-loaded GPS from splash if available (instant first fix)
    final preloaded = PreloadService.initialPosition;
    if (preloaded != null && _pos == null) {
      _pos = LatLng(preloaded.latitude, preloaded.longitude);
      if (mounted) _setState(() {});
    }

    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(S.of(ctx).locationPermissionRequired),
              content: Text(S.of(ctx).locationServicesDisabledMsg),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(S.of(ctx).cancel),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    openAppSettings();
                  },
                  child: Text(S.of(ctx).openSettings),
                ),
              ],
            ),
          );
        }
        return;
      }
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
        if (p == LocationPermission.denied) return;
      }
      if (p == LocationPermission.deniedForever) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(S.of(ctx).locationPermissionRequired),
              content: Text(S.of(ctx).locationRequiredForDriver),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(S.of(ctx).cancel),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    openAppSettings();
                  },
                  child: Text(S.of(ctx).openSettings),
                ),
              ],
            ),
          );
        }
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (!mounted) return;
      final ll = LatLng(pos.latitude, pos.longitude);
      _setState(() => _pos = ll);
      _moveToLatLng(ll);
    } catch (_) {}
  }

  Future<void> _buildVehicleIcons() async {
    // Load ALL icons in parallel instead of sequentially
    final results = await Future.wait([
      CarIconLoader.loadForRideBytes('Suburban'),
      CarIconLoader.loadForRideBytes('Camry'),
      CarIconLoader.loadUberBytes(),
      _loadDriverPhoto(),
      renderCircularPinBytes(icon: CircularPinIcon.person, isPickup: true, radius: 32),
      _loadSearchingCarIcon(),
    ]);
    _suvIconBytes = results[0] as Uint8List?;
    _sedanIconBytes = results[1] as Uint8List?;
    _arrowIconBytes = _suvIconBytes;
    _navCarSprites = null;
    _navCarIconBytes = results[2] as Uint8List?;
    // results[3] is void (_loadDriverPhoto sets _driverPhotoImage internally)
    _goldPinBytes = results[4] as Uint8List?;
    _searchingCarBytes = results[5] as Uint8List?;
    await _goldDot.build(() { if (mounted) _updateDriverAnnotation(); });
    if (mounted) _setState(() {});
  }

  /// Load 3D car PNG for the searching-mode map icon (replaces flat dot).
  Future<Uint8List?> _loadSearchingCarIcon() async {
    try {
      final raw = await rootBundle.load('assets/images/car_sedan.png');
      return _resizePngForMap(raw.buffer.asUint8List(), maxDim: 200);
    } catch (e) {
      debugPrint('[DriverOnline] Failed to load searching car icon: $e');
      return null;
    }
  }

  /// Resize PNG to target dimension (returns PNG bytes).
  Future<Uint8List> _resizePngForMap(Uint8List pngBytes, {int maxDim = 200}) async {
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
    final byteData = await resized.toByteData(format: ui.ImageByteFormat.png);
    resized.dispose();
    picture.dispose();
    img.dispose();
    return byteData!.buffer.asUint8List();
  }

  /// Download and decode the driver's profile photo for the map marker.
  Future<void> _loadDriverPhoto() async {
    final url = widget.photoUrl;
    if (url == null || url.isEmpty) return;
    try {
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode == 200) {
        final codec = await ui.instantiateImageCodec(resp.bodyBytes);
        final frame = await codec.getNextFrame();
        _driverPhotoImage = frame.image;
      }
    } catch (_) {
      // fallback to golden dot
    }
  }

  /// Renders a top-down car marker with proper car silhouette using Canvas.
  ///  - Car points UP (north) so `rotation = bearing` works correctly.
  ///  - Shaped like a real car: rounded nose, wide body, tapered trunk.
  ///  - 3D depth panels visible at 55° tilt.
  Future<Uint8List> _paintCarSprite({
    required Color bodyColor,
    required Color bodyHighlight,
    required Color windowColor,
    required Color windowShine,
    required Color trimColor,
    required Color wheelColor,
    required Color shadowColor,
    required Color headlightColor,
    required Color taillightColor,
    required double widthRatio,
    required double heightRatio,
    required double roofHeightRatio,
  }) async {
    const double cW = 180.0;
    const double cH = 300.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, cW, cH));

    final double cx = cW / 2;
    final double cy = cH / 2;
    final double bW = 60.0 * widthRatio;   // half-width at widest
    final double bH = 100.0 * heightRatio; // half-height
    final double depth = 20.0 * heightRatio;

    // ── 1. DROP SHADOW ───────────────────────────────────────────────────
    canvas.drawPath(
      _carBodyPath(cx, cy + 5, bW + 8, bH + 6),
      Paint()
        ..color = shadowColor
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );

    // ── 2. 3D DEPTH — bottom face (rear bumper, visible when tilted) ─────
    canvas.drawPath(
      _carBodyPath(cx, cy + depth * 0.45, bW, bH).shift(const Offset(0, 2)),
      Paint()..color = Color.lerp(bodyColor, Colors.black, 0.50)!,
    );
    // Left side depth strip
    final sideL = Path()
      ..moveTo(cx - bW * 0.92, cy - bH * 0.55)
      ..lineTo(cx - bW * 0.92 - depth * 0.3, cy - bH * 0.45)
      ..lineTo(cx - bW * 0.92 - depth * 0.3, cy + bH * 0.75 + depth * 0.4)
      ..lineTo(cx - bW * 0.78, cy + bH * 0.85)
      ..close();
    canvas.drawPath(sideL, Paint()..color = Color.lerp(bodyColor, Colors.black, 0.38)!);
    // Right side depth strip
    final sideR = Path()
      ..moveTo(cx + bW * 0.92, cy - bH * 0.55)
      ..lineTo(cx + bW * 0.92 + depth * 0.3, cy - bH * 0.45)
      ..lineTo(cx + bW * 0.92 + depth * 0.3, cy + bH * 0.75 + depth * 0.4)
      ..lineTo(cx + bW * 0.78, cy + bH * 0.85)
      ..close();
    canvas.drawPath(sideR, Paint()..color = Color.lerp(bodyColor, Colors.black, 0.28)!);

    // ── 3. WHEELS ────────────────────────────────────────────────────────
    final double wW = 16.0 * widthRatio;
    final double wH = 32.0 * heightRatio;
    final wheels = [
      Offset(cx - bW * 0.94, cy - bH * 0.48),
      Offset(cx + bW * 0.94, cy - bH * 0.48),
      Offset(cx - bW * 0.90, cy + bH * 0.50),
      Offset(cx + bW * 0.90, cy + bH * 0.50),
    ];
    for (final wp in wheels) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: wp, width: wW, height: wH),
          const Radius.circular(4),
        ),
        Paint()..color = wheelColor,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: wp, width: wW * 0.45, height: wH * 0.45),
          const Radius.circular(3),
        ),
        Paint()..color = const Color(0xFF555555),
      );
    }

    // ── 4. BODY (car silhouette path — rounded nose, wide hips, tapered rear)
    final bodyPath = _carBodyPath(cx, cy, bW, bH);
    // Base fill
    canvas.drawPath(bodyPath, Paint()..color = bodyColor);
    // Highlight gradient
    final bodyBounds = bodyPath.getBounds();
    canvas.drawPath(
      bodyPath,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.25, -0.4),
          radius: 0.9,
          colors: [bodyHighlight, bodyColor],
        ).createShader(bodyBounds),
    );
    // Outline
    canvas.drawPath(
      bodyPath,
      Paint()
        ..color = Color.lerp(bodyColor, Colors.black, 0.15)!
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeJoin = StrokeJoin.round,
    );

    // ── 5. HOOD LINES (subtle creases on the hood) ───────────────────────
    for (final sign in [-1.0, 1.0]) {
      canvas.drawLine(
        Offset(cx + sign * bW * 0.28, cy - bH * 0.82),
        Offset(cx + sign * bW * 0.22, cy - bH * 0.38),
        Paint()
          ..color = Color.lerp(bodyColor, Colors.black, 0.08)!
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round,
      );
    }

    // ── 6. WINDSHIELD (front — wider, trapezoid shape) ───────────────────
    final wsPath = Path()
      ..moveTo(cx - bW * 0.58, cy - bH * 0.38)
      ..lineTo(cx - bW * 0.50, cy - bH * 0.12)
      ..lineTo(cx + bW * 0.50, cy - bH * 0.12)
      ..lineTo(cx + bW * 0.58, cy - bH * 0.38)
      ..close();
    canvas.drawPath(wsPath, Paint()..color = windowColor);
    // Sheen
    final sheenPath = Path()
      ..moveTo(cx - bW * 0.52, cy - bH * 0.35)
      ..lineTo(cx - bW * 0.42, cy - bH * 0.16)
      ..lineTo(cx - bW * 0.30, cy - bH * 0.16)
      ..lineTo(cx - bW * 0.38, cy - bH * 0.35)
      ..close();
    canvas.drawPath(sheenPath, Paint()..color = windowShine.withValues(alpha: 0.22));

    // ── 7. ROOF PANEL (between windows) ──────────────────────────────────
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy + bH * 0.04),
          width: bW * 0.94,
          height: bH * 0.22,
        ),
        const Radius.circular(4),
      ),
      Paint()..color = Color.lerp(bodyColor, bodyHighlight, 0.3)!,
    );

    // ── 8. REAR WINDOW (narrower trapezoid) ──────────────────────────────
    final rwPath = Path()
      ..moveTo(cx - bW * 0.48, cy + bH * 0.18)
      ..lineTo(cx - bW * 0.42, cy + bH * 0.40)
      ..lineTo(cx + bW * 0.42, cy + bH * 0.40)
      ..lineTo(cx + bW * 0.48, cy + bH * 0.18)
      ..close();
    canvas.drawPath(rwPath, Paint()..color = windowColor);

    // ── 9. SIDE WINDOWS (small trapezoids left & right) ──────────────────
    for (final sign in [-1.0, 1.0]) {
      final swPath = Path()
        ..moveTo(cx + sign * bW * 0.54, cy - bH * 0.32)
        ..lineTo(cx + sign * bW * 0.82, cy - bH * 0.22)
        ..lineTo(cx + sign * bW * 0.82, cy + bH * 0.12)
        ..lineTo(cx + sign * bW * 0.54, cy + bH * 0.12)
        ..close();
      canvas.drawPath(swPath, Paint()..color = windowColor.withValues(alpha: 0.7));
    }

    // ── 10. HEADLIGHTS (wraparound at front corners) ─────────────────────
    for (final sign in [-1.0, 1.0]) {
      final hlPath = Path()
        ..moveTo(cx + sign * bW * 0.50, cy - bH * 0.88)
        ..quadraticBezierTo(
          cx + sign * bW * 0.82, cy - bH * 0.84,
          cx + sign * bW * 0.78, cy - bH * 0.72,
        )
        ..lineTo(cx + sign * bW * 0.58, cy - bH * 0.74)
        ..close();
      canvas.drawPath(hlPath, Paint()..color = headlightColor);
    }

    // ── 11. TAILLIGHTS (wide bars at rear) ───────────────────────────────
    for (final sign in [-1.0, 1.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx + sign * bW * 0.48, cy + bH * 0.88),
            width: bW * 0.48,
            height: 8,
          ),
          const Radius.circular(4),
        ),
        Paint()..color = taillightColor,
      );
    }
    // Tail connector strip
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy + bH * 0.88),
          width: bW * 0.5,
          height: 4,
        ),
        const Radius.circular(2),
      ),
      Paint()..color = taillightColor.withValues(alpha: 0.4),
    );

    // ── 12. SIDE MIRRORS ─────────────────────────────────────────────────
    for (final sign in [-1.0, 1.0]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx + sign * (bW + 6), cy - bH * 0.28),
          width: 10,
          height: 14,
        ),
        Paint()..color = bodyColor,
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx + sign * (bW + 6), cy - bH * 0.28),
          width: 10,
          height: 14,
        ),
        Paint()
          ..color = Color.lerp(bodyColor, Colors.black, 0.15)!
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }

    // ── 13. ENCODE ───────────────────────────────────────────────────────
    final picture = recorder.endRecording();
    final image = await picture.toImage(cW.toInt(), cH.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return Uint8List(0);
    return byteData.buffer.asUint8List();
  }

  /// Car body silhouette path — rounded nose, wide at cabin, tapered trunk.
  /// Front = top, rear = bottom.
  Path _carBodyPath(double cx, double cy, double bW, double bH) {
    return Path()
      // Start at front-center (nose)
      ..moveTo(cx, cy - bH * 0.95)
      // Front bumper curve (rounded nose)
      ..quadraticBezierTo(cx + bW * 0.55, cy - bH * 0.94, cx + bW * 0.72, cy - bH * 0.78)
      // Front fender flare
      ..quadraticBezierTo(cx + bW * 0.92, cy - bH * 0.62, cx + bW * 0.92, cy - bH * 0.40)
      // Straight body sides (widest point at doors)
      ..lineTo(cx + bW * 0.88, cy + bH * 0.30)
      // Rear fender taper
      ..quadraticBezierTo(cx + bW * 0.86, cy + bH * 0.68, cx + bW * 0.68, cy + bH * 0.85)
      // Rear bumper curve
      ..quadraticBezierTo(cx + bW * 0.40, cy + bH * 0.95, cx, cy + bH * 0.96)
      // Mirror left side
      ..quadraticBezierTo(cx - bW * 0.40, cy + bH * 0.95, cx - bW * 0.68, cy + bH * 0.85)
      ..quadraticBezierTo(cx - bW * 0.86, cy + bH * 0.68, cx - bW * 0.88, cy + bH * 0.30)
      ..lineTo(cx - bW * 0.92, cy - bH * 0.40)
      ..quadraticBezierTo(cx - bW * 0.92, cy - bH * 0.62, cx - bW * 0.72, cy - bH * 0.78)
      ..quadraticBezierTo(cx - bW * 0.55, cy - bH * 0.94, cx, cy - bH * 0.95)
      ..close();
  }

  Future<void> _verifyDriverApproval() async {
    try {
      final me = await ApiService.getMe();
      if (me == null) return;
      final bgStatus = me['background_check_status'] as String? ?? 'none';
      final verStatus = me['verification_status'] as String? ?? 'none';

      // Check user-level approval
      final userApproved = (bgStatus == 'clear' || bgStatus == 'none') &&
          (verStatus == 'approved' || verStatus == 'none');

      // Check vehicle-level docs (insurance, registration) and expiry
      bool vehicleDocsOk = true;
      String? vehicleBlockReason;
      try {
        final v = await ApiService.getVehicle();
        if (v != null) {
          final insOk = v['insurance_valid'] == true;
          final regOk = v['registration_valid'] == true;
          if (!insOk || !regOk) {
            vehicleDocsOk = false;
            final missing = <String>[];
            if (!insOk) missing.add('Insurance');
            if (!regOk) missing.add('Registration');
            vehicleBlockReason = 'Missing: ${missing.join(', ')}';
          }
          // Check expiry dates
          final now = DateTime.now();
          for (final key in ['insurance_expiry', 'registration_expiry']) {
            final expiryStr = (v[key] ?? '') as String;
            if (expiryStr.isNotEmpty) {
              final dt = DateTime.tryParse(expiryStr);
              if (dt != null && dt.isBefore(now)) {
                vehicleDocsOk = false;
                vehicleBlockReason = 'One or more documents have expired. Please upload updated documents.';
                break;
              }
            }
          }
        }
      } catch (_) {}

      if (userApproved && vehicleDocsOk) {
        _approvalGatePassed = true;
        return;
      }

      _approvalGatePassed = false;
      if (!mounted) return;
      String title;
      String message;

      if (!userApproved) {
        if (bgStatus == 'pending' || bgStatus == 'processing') {
          title = 'Background Check In Progress';
          message = 'Your background check is still being processed. You\'ll be notified when it\'s complete.';
        } else if (bgStatus == 'consider' || bgStatus == 'suspended') {
          title = 'Background Check Issue';
          message = 'There is an issue with your background check. Please contact support.';
        } else {
          title = 'Verification Required';
          message = 'Please complete your documents and background check before going online.';
        }
      } else {
        title = 'Vehicle Documents Required';
        message = 'You need to upload your vehicle documents before going online.\n\n${vehicleBlockReason ?? ''}\n\nGo to Vehicle > upload the missing documents.';
      }

      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1C1C1E),
          title: Text(title, style: const TextStyle(color: Colors.white)),
          content: Text(message, style: TextStyle(color: Colors.white.withValues(alpha: 0.7))),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK', style: TextStyle(color: Color(0xFFE8C547))),
            ),
          ],
        ),
      );
    } catch (e) {
      debugPrint('_verifyDriverApproval error: $e');
      _approvalGatePassed = true;
    }
  }

  void _goOnlineBackend() {
    if (_driverId == null) {
      debugPrint('âš ï¸ _goOnlineBackend: _driverId is null, skipping');
      return;
    }
    debugPrint(
      'ðŸŸ¢ Going online: driverId=$_driverId lat=${_pos?.latitude} lng=${_pos?.longitude}',
    );
    if (!_approvalGatePassed) {
      debugPrint('_goOnlineBackend: approval gate not passed, skipping');
      return;
    }
    if (_pos == null) {
      debugPrint('⚠️ _goOnlineBackend: GPS not ready yet, retrying in 3s');
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && _phase == _Phase.searching) _goOnlineBackend();
      });
      return;
    }
    // Save last known location for startup pre-caching
    LocalCache.set('last_driver_lat', _pos!.latitude);
    LocalCache.set('last_driver_lng', _pos!.longitude);
    ApiService.updateDriverLocation(
          driverId: _driverId!,
          lat: _pos!.latitude,
          lng: _pos!.longitude,
          isOnline: true,
        )
        .then((_) {
          debugPrint('âœ… Driver online successfully');
          AnalyticsService.instance.logDriverOnline();
          // Show persistent notification (fire-and-forget, non-blocking)
          NotificationService.showDriverOnlineNotification();
          // Subscribe to scheduled rides topic — receives FCM when new
          // scheduled trips enter the marketplace.
          FirebaseMessaging.instance.subscribeToTopic('drivers_available').catchError(
            (e) => debugPrint('FCM subscribeToTopic drivers_available failed: $e'),
          );
        })
        .catchError((e) {
          debugPrint('âŒ Failed to go online: $e');
          // Retry after 5s so driver doesn't stay silently offline
          Future.delayed(const Duration(seconds: 5), () {
            if (mounted && _phase == _Phase.searching) {
              debugPrint('[DriverOnline] Retrying _goOnlineBackend after failure');
              _goOnlineBackend();
            }
          });
        });
  }

  void _goOfflineBackend() {
    if (_driverId == null || _pos == null) return;
    AnalyticsService.instance.logDriverOffline();
    NotificationService.cancelDriverOnlineNotification();
    NotificationService.cancelOfferNotifications();
    // Unsubscribe from scheduled rides topic when going offline.
    FirebaseMessaging.instance.unsubscribeFromTopic('drivers_available').catchError(
      (e) => debugPrint('FCM unsubscribeFromTopic drivers_available failed: $e'),
    );
    ApiService.updateDriverLocation(
      driverId: _driverId!,
      lat: _pos!.latitude,
      lng: _pos!.longitude,
      isOnline: false,
    ).catchError((_) => <String, dynamic>{});
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  DRIVER POSITION STREAM (smooth movement on map)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _startPosStream() {
    // Start GpsService for Firebase RTDB uploads + presence
    if (_driverId != null) {
      _gpsService.startTracking(_driverId.toString());
    }

    _posStream =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 5, // 5 meters — frequent updates for smooth rider tracking
          ),
        ).listen((pos) {
          if (!mounted) return;
          final newLL = LatLng(pos.latitude, pos.longitude);
          _smoothedBearing = _lerpAngle(_smoothedBearing, pos.heading, 0.25);
          _currentSpeedMph = (pos.speed * 2.23694).clamp(0.0, 200.0);
          // Snap to route polyline — prevents GPS drift off-road
          final snappedLL = _snapToRoute(newLL);
          _smoothMoveTo(snappedLL, _smoothedBearing);

          // Feed GpsService for RTDB upload (800ms throttled)
          _gpsService.updatePosition(newLL, pos.heading, pos.speed);

          _trimRouteBehindDriver(snappedLL);

          // Phase-specific nav stats (camera handled by _onDriverAnimTick)
          if (_phase == _Phase.routeSummary) {
            final dist = _hav(newLL, _dropoffLL);
            final eta = (dist * 1000 / 17.88 / 60).ceil().clamp(0, 99);
            _navDist = dist;
            _navEta = eta;
            final now = DateTime.now();
            if (now.difference(_lastNavSetState).inMilliseconds > 500) {
              _lastNavSetState = now;
              _setState(() {});
            }
          } else if (_phase == _Phase.enRouteToPickup) {
            _updateNavState(newLL);
            final dist = _hav(newLL, _pickupLL);
            final eta = (dist * 1000 / 17.88 / 60).ceil().clamp(0, 99);
            final progress = _distToPickup > 0
                ? (1.0 - dist / _distToPickup).clamp(0.0, 1.0)
                : 0.0;
            _navDist = dist;
            _navEta = eta;
            _navProgress = progress;
            final now1 = DateTime.now();
            if (now1.difference(_lastNavSetState).inMilliseconds > 500) {
              _lastNavSetState = now1;
              _setState(() {});
            }
            if (dist < 0.05) {
              _onNearPickup();
            }
          } else if (_phase == _Phase.inTrip) {
            _updateNavState(newLL);
            final dist = _hav(newLL, _dropoffLL);
            final eta = (dist * 1000 / 17.88 / 60).ceil().clamp(0, 99);
            final progress = _tripDist > 0
                ? (1.0 - dist / _tripDist).clamp(0.0, 1.0)
                : 0.0;
            _navDist = dist;
            _navEta = eta;
            _navProgress = progress;
            final now2 = DateTime.now();
            if (now2.difference(_lastNavSetState).inMilliseconds > 500) {
              _lastNavSetState = now2;
              _setState(() {});
            }
            if (dist < 0.05) {
              _onNearDropoff();
            }
          }

          // Throttle backend location updates to max once per 5 seconds
          final now = DateTime.now();
          if (_driverId != null && now.difference(_lastBackendLocSend).inSeconds >= 5) {
            _lastBackendLocSend = now;
            ApiService.updateDriverLocation(
              driverId: _driverId!,
              lat: pos.latitude,
              lng: pos.longitude,
            ).catchError((_) => <String, dynamic>{});
          }
          // Sync driver GPS to Firestore so rider tracking gets real position
          if (_tripId != null) {
            TripFirestoreService.syncDriverLocation(
              'sql_$_tripId',
              pos.latitude,
              pos.longitude,
              _smoothedBearing,
            );
          }
        }, onError: (_) {});
  }

  /// Update turn-by-turn navigation state from GPS position.
  void _updateNavState(LatLng pos) {
    if (!_navService.isNavigating) return;
    final state = _navService.updatePosition(pos);
    if (state == null) return;

    _navState = state;

    // Update displayed instruction & distance from NavigationService
    if (state.currentInstruction.isNotEmpty) {
      _navInstruct = state.currentInstruction;
    }
    _navEta = state.etaMinutes;
    _navDist = state.distanceRemainingMiles;
    _navProgress = state.progress;

    // Off-route detection & auto-reroute
    if (state.isOffRoute && !_isRerouting) {
      final now = DateTime.now();
      final canReroute =
          _lastRerouteTime == null ||
          now.difference(_lastRerouteTime!).inSeconds > 10;
      if (canReroute && _rerouteCount < 5) {
        _triggerReroute(pos);
      }
    }
  }

  /// Reroute from current position to the active destination.
  Future<void> _triggerReroute(LatLng from) async {
    if (_isRerouting) return;
    _isRerouting = true;
    _lastRerouteTime = DateTime.now();
    _rerouteCount++;
    debugPrint('Rerouting (#$_rerouteCount)');
    HapticFeedback.mediumImpact();

    final dest = _phase == _Phase.enRouteToPickup ? _pickupLL : _dropoffLL;
    final routeId = _phase == _Phase.enRouteToPickup ? 'pickup' : 'trip';
    await _drawRoute(from, dest, routeId, _navyRoute);
    _isRerouting = false;
  }

  void _onNearPickup() {
    if (_nearPickupNotified || _phase != _Phase.enRouteToPickup) return;
    _nearPickupNotified = true;
    HapticFeedback.heavyImpact();
    // Send final position to backend so rider sees driver at pickup
    if (_driverId != null) {
      ApiService.updateDriverLocation(
        driverId: _driverId!,
        lat: _pickupLL.latitude,
        lng: _pickupLL.longitude,
      ).catchError((_) => <String, dynamic>{});
    }
    // Show ARRIVED button
    _setState(() {});
  }

  void _onNearDropoff() {
    if (_nearDropoffNotified || _phase != _Phase.inTrip) return;
    _nearDropoffNotified = true;
    HapticFeedback.heavyImpact();
    // Send final position to backend so rider sees driver at dropoff
    if (_driverId != null) {
      ApiService.updateDriverLocation(
        driverId: _driverId!,
        lat: _dropoffLL.latitude,
        lng: _dropoffLL.longitude,
      ).catchError((_) => <String, dynamic>{});
    }
    // Show FINISH TRIP button in panel
    _setState(() {});
  }

  void _smoothMoveTo(LatLng target, double heading) {
    _targetPos = target;
    _targetHeading = heading;
    // Start the ticker lazily on the first real GPS position so it does not
    // burn CPU during the period before any movement data is available.
    if (!(_smoothTicker?.isTicking ?? false)) {
      _smoothTicker?.start();
    }
  }

  /// Trim the route polyline behind the driver so only upcoming road is shown.
  /// Google Maps navigation style — route "disappears" behind the car.
  void _trimRouteBehindDriver(LatLng driverPos) {
    if (_routePts.length < 3) return;
    if (_phase != _Phase.enRouteToPickup && _phase != _Phase.inTrip) return;

    // Find the closest point on the DISPLAY route (not the simulation copy)
    int closestIdx = 0;
    double closestDist = double.infinity;
    for (int i = 0; i < _routePts.length; i++) {
      final d = _hav(driverPos, _routePts[i]) * 1000; // meters
      if (d < closestDist) {
        closestDist = d;
        closestIdx = i;
      }
    }

    // Only trim if we've passed at least 1 point
    if (closestIdx > 0) {
      _routePts = _routePts.sublist(closestIdx);
    }
    // Always put driver at front for seamless line
    if (_routePts.isNotEmpty) {
      _routePts[0] = driverPos;
    }

    // Rebuild route annotation with trimmed route
    _setRouteAnnotation(List.from(_routePts), _navyRoute);
  }

  /// Continuous 60fps ticker — exponential decay toward target position.
  /// Never resets, never stutters. Each frame closes 18% of the remaining gap.
  void _onSmoothTick(Duration elapsed) {
    if (!mounted || _pos == null) return;
    if (_targetPos.latitude == 0 && _targetPos.longitude == 0) return;

    // Time-based decay so animation is frame-rate independent
    final dtMs = (elapsed - _lastTickElapsed).inMilliseconds.clamp(1, 50);
    _lastTickElapsed = elapsed;
    final dt = dtMs / 16.667; // normalize to 60fps frame

    // Position: exponential decay — 22% of gap per frame at 60fps (snappier)
    const posDecay = 0.22;
    final posFactor = 1.0 - _pow(1.0 - posDecay, dt);
    final newLat = _pos!.latitude + (_targetPos.latitude - _pos!.latitude) * posFactor;
    final newLng = _pos!.longitude + (_targetPos.longitude - _pos!.longitude) * posFactor;
    _pos = LatLng(newLat, newLng);

    // Bearing: exponential decay — 16% per frame, shortest-arc (faster nose rotation)
    const brgDecay = 0.16;
    final brgFactor = 1.0 - _pow(1.0 - brgDecay, dt);
    double diff = _targetHeading - _heading;
    while (diff > 180) { diff -= 360; }
    while (diff < -180) { diff += 360; }
    _heading += diff * brgFactor;

    // Unified camera following (single source of truth for all phases)
    // Skip camera control when offer animation is running or route is previewing
    final isNav = _phase == _Phase.enRouteToPickup || _phase == _Phase.inTrip;
    final offerActive = _isCardAnimating || _previewingOffer != null;
    if (_phase == _Phase.searching && !offerActive) {
      // Gentle camera follow — car moves ON the map instead of map sliding around.
      // Only re-center when driver drifts >30% from screen center (≈ lat/lng gap).
      final latDrift = (_pos!.latitude - (_lastCamLat ?? _pos!.latitude)).abs();
      final lngDrift = (_pos!.longitude - (_lastCamLng ?? _pos!.longitude)).abs();
      if (_lastCamLat == null || latDrift > 0.0008 || lngDrift > 0.0012) {
        _lastCamLat = _pos!.latitude;
        _lastCamLng = _pos!.longitude;
        _map?.flyTo(
          mapbox.CameraOptions(
            center: mapbox.Point(
                coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),
            zoom: 15.5,
            bearing: 0,
            pitch: 20,
          ),
          mapbox.MapAnimationOptions(duration: 1200),
        );
      }
    } else if (isNav && _cameraFollowing) {
      _cameraBearing = _heading;
      _map?.setCamera(
        mapbox.CameraOptions(
          center: mapbox.Point(
              coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),
          zoom: 17.5,
          bearing: _heading,
          pitch: 55,
        ),
      );
    }

    _updateDriverAnnotation();

    // Stop ticker when close enough to target — saves CPU when idle/stationary
    final latGap = (_targetPos.latitude - _pos!.latitude).abs();
    final lngGap = (_targetPos.longitude - _pos!.longitude).abs();
    if (latGap < 0.000001 && lngGap < 0.000001) {
      _smoothTicker?.stop();
    }

    // Throttle widget-tree rebuilds to ~15fps — map annotation updates every frame
    // but Flutter setState only fires 4x/sec so buttons stay responsive.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastUiRebuildMs >= 66) {
      _lastUiRebuildMs = nowMs;
      _setState(() {});
    }
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  POLLING & CLOCK
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _startPolling() {
    _pollT?.cancel();
    _offerSseSub?.cancel();
    _sseReconnectTimer?.cancel();
    _sseActive = false;

    _connectSse();

    // Polling fallback — only used when SSE is DOWN to save battery
    _poll();
    _pollT = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || _phase != _Phase.searching) return;
      if (_sseActive) return; // SSE handles it — skip polling entirely
      _poll();
    });
  }

  /// Poll for available scheduled rides every 90 seconds.
  void _startScheduledPoll() {
    _scheduledPollTimer?.cancel();
    _fetchScheduledCount();
    _scheduledPollTimer = Timer.periodic(const Duration(seconds: 90), (_) {
      if (mounted) _fetchScheduledCount();
    });
  }

  Future<void> _fetchScheduledCount() async {
    try {
      final trips = await ApiService.getAvailableScheduledTrips(lat: 0, lng: 0, radiusKm: 100);
      if (!mounted) return;
      final newCount = trips.length;
      final oldCount = _scheduledAvailCount;
      _setState(() => _scheduledAvailCount = newCount);

      // Trigger bounce + toast when new scheduled rides appear
      if (newCount > oldCount && newCount > 0) {
        _scheduledBounceCtrl?.forward(from: 0);
        if (oldCount == 0 || newCount > _prevScheduledCount) {
          _setState(() => _showScheduledToast = true);
          Future.delayed(const Duration(seconds: 4), () {
            if (mounted) _setState(() => _showScheduledToast = false);
          });
        }
      }
      _prevScheduledCount = newCount;
    } catch (_) {}
  }

  /// Connect (or reconnect) the SSE offer stream.
  /// Automatically retries after 2 seconds on error or stream close.
  void _connectSse() {
    _offerSseSub?.cancel();
    _sseReconnectTimer?.cancel();
    if (_driverId == null || !mounted) return;

    void scheduleReconnect(String reason) {
      debugPrint('SSE $reason — reconnecting in 2s');
      _sseActive = false;
      if (mounted && _phase == _Phase.searching) {
        _sseReconnectTimer = Timer(const Duration(seconds: 2), _connectSse);
      }
    }

    _offerSseSub = ApiService.streamDriverOffers(_driverId!).listen(
      (offers) {
        _sseActive = true;
        debugPrint('SSE offers: ${offers.length}');
        if (!mounted || _phase != _Phase.searching) return;
        _applyOffers(offers);
      },
      onError: (e) => scheduleReconnect('error: $e'),
      onDone: () => scheduleReconnect('stream ended'),
    );
  }

  /// Apply incoming offers to UI (shared by SSE + polling).
  void _applyOffers(List<Map<String, dynamic>> offers) {
    // Filter out locally rejected offers (prevents re-showing before backend processes rejection)
    final filtered = offers.where((o) {
      final oid = o['offer_id'] as int?;
      return oid == null || !_rejectedOfferIds.contains(oid);
    }).toList();

    final hadOffers = _pendingOffers.isNotEmpty;

    // Detect whether the leading offer has changed — covers both the 0→N transition
    // and the case where a new offer replaces an existing one while cards are visible.
    final prevFirstId = _pendingOffers.isNotEmpty
        ? (_pendingOffers.first['offer_id'] ?? _pendingOffers.first['id'])?.toString()
        : null;
    final nextFirstId = filtered.isNotEmpty
        ? (filtered.first['offer_id'] ?? filtered.first['id'])?.toString()
        : null;
    final isNewFirstOffer = nextFirstId != null && nextFirstId != prevFirstId;

    if (isNewFirstOffer) {
      HapticFeedback.heavyImpact();
      final firstOffer = filtered.first;
      if (_appInForeground) {
        NotificationService.playOfferSound();
      }
      NotificationService.showOfferNotification(
        title: S.of(context).newRideOffer,
        body: '',
        offerId: (firstOffer['offer_id'] as num? ?? 0).toInt(),
        payload: 'trip_offer',
        appInForeground: _appInForeground,
      );
    }

    _setState(() {
      _pendingOffers = filtered;
      if (filtered.isNotEmpty) {
        _currentOfferIndex = _currentOfferIndex.clamp(0, filtered.length - 1);
      }
      if (filtered.isNotEmpty && !hadOffers) _hideFindingBar = true;
      if (filtered.isEmpty && hadOffers) _hideFindingBar = false;
    });
    _preFetchOfferRoutes(filtered);
    if (isNewFirstOffer) {
      _autoTriggerRoutePreview(filtered.first);
    }
  }

  Future<void> _poll() async {
    if (_isPollingOffers) return;
    _isPollingOffers = true;
    if (_driverId == null) {
      debugPrint(
        'âš ï¸ _poll: _driverId is null, retrying getCurrentUserId...',
      );
      try {
        final id = await ApiService.getCurrentUserId();
        if (id != null) {
          _driverId = id;
          debugPrint('âœ… Recovered driverId=$_driverId during polling');
          _goOnlineBackend(); // Re-establish online status
        }
      } catch (_) {}
      if (_driverId == null) {
        _isPollingOffers = false;
        return;
      }
    }
    // Heartbeat: keep last_active_at fresh so dispatch doesn't skip us.
    // Only send if GPS stream hasn't already sent recently (avoid duplicates).
    final now = DateTime.now();
    if (_driverId != null && _pos != null && now.difference(_lastBackendLocSend).inSeconds >= 2) {
      _lastBackendLocSend = now;
      ApiService.updateDriverLocation(
        driverId: _driverId!,
        lat: _pos!.latitude,
        lng: _pos!.longitude,
      ).catchError((_) => <String, dynamic>{});
    }
    try {
      final offers = await ApiService.getDriverPendingOffers(_driverId!);
      if (!mounted || _phase != _Phase.searching) return;
      _applyOffers(offers);
    } catch (e) {
      debugPrint('Poll error: $e');
    } finally {
      _isPollingOffers = false;
    }
  }

  void _startClock() {
    _clock = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) _setState(() => _online += const Duration(seconds: 5));
    });
  }

  Future<void> _acceptOffer(Map<String, dynamic> r) async {
    // Prevent double-tap
    final oid = (r['offer_id'] ?? r['id'] ?? '').toString();
    if (_offerAcceptState != _OfferAcceptState.normal) return;

    HapticFeedback.heavyImpact();

    // Block further taps but do NOT change visual state — card stays normal
    // until we navigate away to the full-screen confirmation.
    _setState(() {
      _offerAcceptState = _OfferAcceptState.routing; // blocks re-entry, no visual change
    });

    final offerId = r['offer_id'] as int?;
    final tripId = r['trip_id'] as int? ?? r['id'] as int?;

    final acceptFuture = (() async {
      if (offerId != null && _driverId != null) {
        await ApiService.acceptRideOffer(
          offerId: offerId,
          driverId: _driverId!,
        );
        return true;
      }
      if (tripId != null && _driverId != null) {
        await ApiService.acceptTrip(tripId: tripId, driverId: _driverId!);
        return true;
      }
      return false;
    })();

    // Reject all other pending offers silently
    for (final other in _pendingOffers) {
      final otherId = other['offer_id'] as int?;
      if (otherId != null && otherId != offerId && _driverId != null) {
        ApiService.rejectRideOffer(
          offerId: otherId,
          driverId: _driverId!,
        ).catchError((_) => <String, dynamic>{});
      }
    }

    // Populate active trip data from the accepted offer
    final name = (r['rider_name'] ?? 'Rider') as String;
    _pickupLL = LatLng(
      (r['pickup_lat'] as num?)?.toDouble() ?? 0.0,
      (r['pickup_lng'] as num?)?.toDouble() ?? 0.0,
    );
    _dropoffLL = LatLng(
      (r['dropoff_lat'] as num?)?.toDouble() ?? 0.0,
      (r['dropoff_lng'] as num?)?.toDouble() ?? 0.0,
    );

    _currentOfferId = offerId;
    _tripId = tripId;
    _riderName = name;
    _riderInit = name.isNotEmpty ? name[0].toUpperCase() : '?';
    _riderPhotoUrl = _normalizePhotoUrl(r['rider_photo_url'] ?? r['photo_url'] ?? '');
    _riderPhone = (r['rider_phone'] ?? '') as String;
    _riderId = (r['rider_id'] ?? '').toString();
    _pickupAddr = r['pickup_address'] ?? 'Pickup';
    _dropoffAddr = r['dropoff_address'] ?? 'Drop-off';
    _fare = (r['fare'] as num?)?.toDouble() ?? 0;
    _vehicleType = _mapRideType((r['vehicle_type'] ?? 'Comfort') as String);
    _distToPickup = _pos != null ? _hav(_pos!, _pickupLL) : 0.0;
    _etaToPickup = (_distToPickup * 1000 / 17.88 / 60).ceil().clamp(1, 99);
    _tripDist = _hav(_pickupLL, _dropoffLL);
    _tripEta = (_tripDist * 1000 / 17.88 / 60).ceil().clamp(1, 99);

    // ── Extract cached route BEFORE clearing cache ──
    final cachedRouteData = _routeCache[oid];
    final preRoutePoints = cachedRouteData?.segOne;

    _setState(() => _pendingOffers = []);
    _routeCache.clear();
    _expandedOfferIds.clear();
    _pollT?.cancel();
    _previewingOffer = null;
    _offerRouteShown = false;
    _fullSegOne = [];
    _fullSegTwo = [];
    _nearPickupNotified = false;
    _nearDropoffNotified = false;
    await _clearAllAnnotations();
    if (_pos != null) {
      _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
    }

    // ── Reset offer state and navigate to full-screen accepted screen ──
    _tappedCardIds.clear();
    _lastAutoTriggeredOfferId = null;
    _setState(() {
      _offerAcceptState = _OfferAcceptState.normal;
      _acceptingCardId = null;
    });

    // Write accepted status to Firestore immediately — bypasses the 2-second
    // backend→Firestore sync delay so the rider's listener fires instantly.
    if (tripId != null) {
      final fsDocId = 'sql_$tripId';
      final driverUser = await UserSession.getUser();
      final driverFirstName = driverUser?['firstName']?.toString() ?? '';
      final driverLastName = driverUser?['lastName']?.toString() ?? '';
      final driverPhone = driverUser?['phone']?.toString() ?? '';
      final fullName = '$driverFirstName $driverLastName'.trim();
      unawaited(
        FirebaseFirestore.instance
            .collection('trips')
            .doc(fsDocId)
            .set({
          'status': 'driver_en_route',
          'driver_id': _driverId ?? 0,
          'driverId': _driverId?.toString() ?? '',
          'driver_name': fullName.isNotEmpty ? fullName : 'Driver',
          'driverName': fullName.isNotEmpty ? fullName : 'Driver',
          'driver_phone': driverPhone,
          'driverPhone': driverPhone,
          'driver_photo_url': widget.photoUrl ?? _driverPhotoUrl ?? '',
          'driverPhotoUrl': widget.photoUrl ?? _driverPhotoUrl ?? '',
          'acceptedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true)).catchError((_) {}),
      );
    }

    if (!mounted) return;
    final riderPhotoUrl = _normalizePhotoUrl(r['rider_photo_url'] ?? r['photo_url'] ?? '');
    final riderRating   = (r['rider_rating']   as num?)?.toDouble() ?? 4.8;
    final riderInit     = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final navFuture = Navigator.of(context).push<String>(
      smoothFadeRoute(
        TripAcceptedScreen(
          tripId:         tripId ?? offerId ?? 0,
          riderName:      name,
          riderInitials:  riderInit,
          riderPhotoUrl:  riderPhotoUrl.isNotEmpty ? riderPhotoUrl : null,
          riderRating:    riderRating,
          riderId:        int.tryParse(_riderId),
          pickupLatLng:   _pickupLL,
          dropoffLatLng:  _dropoffLL,
          pickupAddress:  _pickupAddr,
          dropoffAddress: _dropoffAddr,
          fare:           _fare,
          vehicleType:    _vehicleType,
          driverPos:      _pos ?? _pickupLL,
          distToPickupKm: _distToPickup,
          etaMinutes:     _etaToPickup,
          riderPhone:     _riderPhone,
          routePoints:    preRoutePoints,
        ),
      ),
    );
    try {
      await acceptFuture;
    } catch (e) {
      if (!mounted) return;
      _snack(S.of(context).tripNoLongerAvailable);
      _cancel();
      return;
    }
    final result = await navFuture;
    if (!mounted) return;
    if (result == 'completed') {
      // Show the earnings / completed overlay (mirrors _complete())
      _setState(() {
        _trips++;
        _prevEarnings = _earnings;
        _earnings += _fare;
        _prevLastTripEarnings = _lastTripEarnings;
        _lastTripEarnings = _fare;
        _phase = _Phase.completed;
        _stars = 5;
      });
      _syncSearchPulse();
      _cacheEarnings();
      _doneCtrl.forward(from: 0);
    } else {
      // Cancelled or back-pressed — return to searching
      _cancel();
    }
  }

  Future<void> _rejectOffer(Map<String, dynamic> r) async {
    HapticFeedback.lightImpact();
    final offerId = r['offer_id'] as int?;
    if (offerId != null) _rejectedOfferIds.add(offerId);

    // INSTANT dismiss — remove card + clear map in the same frame
    _setState(() {
      _rejectingOfferId = null;
      _pendingOffers.removeWhere((o) => o['offer_id'] == offerId);
      if (_pendingOffers.isEmpty) _hideFindingBar = false;
      _previewingOffer = null;
      _offerRouteShown = false;
      _fullSegOne = [];
      _fullSegTwo = [];
    });
    _rejectSlideCtrl?.reset();
    await _clearAllAnnotations();
    if (_pos != null) _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);

    // Fire-and-forget API rejection — UI already updated
    if (offerId != null && _driverId != null) {
      ApiService.rejectRideOffer(
        offerId: offerId,
        driverId: _driverId!,
      ).catchError((_) => <String, dynamic>{});
    }
    if (offerId != null) _routeCache.remove(offerId.toString());
  }

  // â”€â”€ _accept and _decline removed — now using _acceptOffer / _rejectOffer â”€â”€

  Future<void> _runAcceptCameraSequence() async {
    if (_map == null || !mounted) return;

    // Phase 1: Fit route bounds with padding for bottom card
    try {
      final cam = await _map!.cameraForCoordinatesPadding(
        [
          mapbox.Point(coordinates: mapbox.Position(_pickupLL.longitude, _pickupLL.latitude)),
          mapbox.Point(coordinates: mapbox.Position(_dropoffLL.longitude, _dropoffLL.latitude)),
        ],
        mapbox.CameraOptions(),
        mapbox.MbxEdgeInsets(top: 80, left: 60, bottom: 280, right: 60),
        null, null,
      );
      if (!mounted) return;
      await _map?.flyTo(cam, mapbox.MapAnimationOptions(duration: 300));
    } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    // Phase 2: Tilt to 55
    _map?.flyTo(
      mapbox.CameraOptions(pitch: 55),
      mapbox.MapAnimationOptions(duration: 800),
    );
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;

    // Phase 3: Rotate 20
    _map?.flyTo(
      mapbox.CameraOptions(bearing: 20),
      mapbox.MapAnimationOptions(duration: 600),
    );
  }

  Future<void> _showPickupSummary() async {
    if (_tripId != null) {
      try {
        await ApiService.updateTripStatus(
          tripId: _tripId!,
          status: 'driver_en_route',
        );
      } catch (_) {}
    }
    if (!mounted) return;
    _setState(() {
      _isPickupSummary = true;
      _phase = _Phase.routeSummary;
      _cameraFollowing = false;
      _navDist = _hav(_pos!, _pickupLL);
      _navEta = (_navDist * 1000 / 17.88 / 60).ceil().clamp(1, 99);
      _navInstruct = S.of(context).headToPickup;
      _navProgress = 0;
      _slideVal = 0;
      _slid = false;
    });
    _syncSearchPulse();
    _setPickupDropoffAnnotations();
    await _drawRoute(_pos!, _pickupLL, 'pickup', _navyRoute);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fitBounds(_pos!, _pickupLL);
    });
  }

  Future<void> _toPickup() async {
    if (_tripId != null) {
      try {
        await ApiService.updateTripStatus(
          tripId: _tripId!,
          status: 'driver_en_route',
        );
      } catch (_) {}
    }
    if (!mounted) return;
    _setState(() {
      _phase = _Phase.enRouteToPickup;
      _cameraFollowing = true;
      _reFollowTimer?.cancel();
      _navDist = _hav(_pos!, _pickupLL);
      _navEta = (_navDist * 1000 / 17.88 / 60).ceil().clamp(1, 99);
      _navInstruct = S.of(context).headToPickup;
      _navProgress = 0;
      _slideVal = 0;
      _slid = false;
    });
    _syncSearchPulse();
    _setPickupAnnotation();
    await _drawRoute(_pos!, _pickupLL, 'pickup', _navyRoute);
    // Fit bounds after frame renders with updated map padding
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fitBounds(_pos!, _pickupLL);
    });
  }

  Future<void> _arrivePickup() async {
    HapticFeedback.mediumImpact();
    if (_tripId != null) {
      try {
        await ApiService.updateTripStatus(tripId: _tripId!, status: 'arrived');
      } catch (_) {}
    }
    if (!mounted) return;
    _setState(() {
      _phase = _Phase.arrivedAtPickup;
      _slideVal = 0;
      _slid = false;
    });
    _syncSearchPulse();
    _clearRouteAnnotation();
    _setDropoffAnnotation();
    _animateToPosition(_pickupLL, zoom: 17);
  }

  Future<void> _startTrip() async {
    HapticFeedback.heavyImpact();

    // ── Check if rider confirmed pickup ──
    bool riderConfirmed = false;
    if (_tripId != null) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('trips')
            .doc('sql_$_tripId')
            .get();
        riderConfirmed = doc.data()?['rider_confirmed_pickup'] == true;
      } catch (_) {}
    }
    if (!riderConfirmed && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(S.of(context).riderNotConfirmedStarting),
        duration: const Duration(seconds: 2),
      ));
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
    }

    if (_tripId != null) {
      try {
        await ApiService.updateTripStatus(tripId: _tripId!, status: 'in_trip');
      } catch (_) {}
    }
    if (!mounted) return;
    // Show route summary with Start Navigation button
    _setState(() {
      _isPickupSummary = false;
      _phase = _Phase.routeSummary;
      _cameraFollowing = false;
      _reFollowTimer?.cancel();
      _navDist = _hav(_pos!, _dropoffLL);
      _navEta = (_navDist * 1000 / 17.88 / 60).ceil().clamp(1, 99);
      _navInstruct = S.of(context).headToDropOff;
      _navProgress = 0;
      _slideVal = 0;
      _slid = false;
    });
    _syncSearchPulse();
    _setDropoffAnnotation();
    await _drawRoute(_pos!, _dropoffLL, 'trip', _navyRoute);
    _nearDropoffNotified = false;
    // Fit bounds after frame renders
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fitBounds(_pos!, _dropoffLL);
    });
  }

  /// User pressed "Start Navigation" from the route summary — begin actual nav.
  /// If _isPickupSummary, transition to enRouteToPickup; otherwise inTrip.
  Future<void> _beginNavigation() async {
    HapticFeedback.heavyImpact();

    if (_isPickupSummary) {
      // ── Navigate to pickup ──
      _setState(() {
        _isPickupSummary = false;
        _phase = _Phase.enRouteToPickup;
        _cameraFollowing = true;
        _reFollowTimer?.cancel();
        _slideVal = 0;
        _slid = false;
      });
      _syncSearchPulse();
      _setPickupAnnotation();
      _cameraBearing = _heading;
      _animateToPosition(_pos!, zoom: 17.5, bearing: _heading, tilt: 55);
      MapLauncherService.prefersInApp().then((inApp) {
        if (!inApp) {
          MapLauncherService.navigate(
            destLat: _pickupLL.latitude,
            destLng: _pickupLL.longitude,
          );
        }
      });
    } else {
      // ── Navigate to dropoff ──
      _setState(() {
        _phase = _Phase.inTrip;
        _cameraFollowing = true;
        _reFollowTimer?.cancel();
        _slideVal = 0;
        _slid = false;
      });
      _syncSearchPulse();
      _setDropoffAnnotation();
      _cameraBearing = _heading;
      _animateToPosition(_pos!, zoom: 17.5, bearing: _heading, tilt: 55);
      MapLauncherService.prefersInApp().then((inApp) {
        if (!inApp) {
          MapLauncherService.navigate(
            destLat: _dropoffLL.latitude,
            destLng: _dropoffLL.longitude,
          );
        }
      });
    }
  }

  void _decline() {
    // Reject all pending offers if any
    for (final offer in _pendingOffers) {
      final oid = offer['offer_id'] as int?;
      if (oid != null && _driverId != null) {
        ApiService.rejectRideOffer(
          offerId: oid,
          driverId: _driverId!,
        ).catchError((_) => <String, dynamic>{});
      }
    }
    if (_currentOfferId != null && _driverId != null) {
      ApiService.rejectRideOffer(
        offerId: _currentOfferId!,
        driverId: _driverId!,
      ).catchError((_) => <String, dynamic>{});
    }
    _navService.stopNavigation();
    _navState = null;
    _currentNavRoute = null;
    _setState(() {
      _phase = _Phase.searching;
      _tripId = null;
      _currentOfferId = null;
      _pendingOffers = [];
    });
    _syncSearchPulse();
    _clearAllAnnotations();
    if (_pos != null) _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
    _startPolling();
  }

  Future<void> _complete() async {
    _navService.stopNavigation();
    _navState = null;
    _currentNavRoute = null;
    HapticFeedback.heavyImpact();
    _navTimer?.cancel();
    if (_tripId != null) {
      try {
        await ApiService.updateTripStatus(
          tripId: _tripId!,
          status: 'completed',
        );
      } catch (_) {}
      // Immediate Firestore sync so rider listener detects completion in real time
      unawaited(TripFirestoreService.syncTripCompleted('sql_$_tripId'));
    }
    if (!mounted) return;
    _setState(() {
      _trips++;
      _prevEarnings = _earnings;
      _earnings += _fare;
      _prevLastTripEarnings = _lastTripEarnings;
      _lastTripEarnings = _fare;
      _phase = _Phase.completed;
      _stars = 5;
    });
    _syncSearchPulse();
    _cacheEarnings();
    _doneCtrl.forward(from: 0);
  }

  void _afterComplete() {
    // Submit the driver's rating for this rider (fire-and-forget)
    if (_tripId != null) {
      ApiService.rateTrip(
        tripId: _tripId!,
        stars: _stars,
      ).catchError((_) => <String, dynamic>{});
      // Clean up RTDB chat node
      ChatService().deleteChat(_tripId.toString());
    }
    _doneCtrl.reverse();
    // INSTANT reset — no delay
    _setState(() {
      _phase = _Phase.searching;
      _tripId = null;
      _currentOfferId = null;
      _routePts = [];
      _pendingOffers = [];
    });
    _syncSearchPulse();
    _clearAllAnnotations();
    if (_pos != null) _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
    _startPolling();
    // Refresh earnings from API so weekly total stays in sync
    _loadAllEarnings();
  }

  void _goOffline() {
    if (!mounted) return;
    // Block going offline while an offer is visible
    if (_pendingOffers.isNotEmpty || _previewingOffer != null) {
      HapticFeedback.heavyImpact();
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            'Active Offer',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          ),
          content: const Text(
            'You have an active ride offer. Accept or dismiss it before going offline.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK', style: TextStyle(color: Color(0xFFE8C547))),
            ),
          ],
        ),
      );
      return;
    }
    HapticFeedback.mediumImpact();
    _goOfflineBackend();

    // Cancel all background tasks before navigating to prevent post-dispose crashes
    _pollT?.cancel();
    _offerSseSub?.cancel();
    _clock?.cancel();
    _earningsRefreshTimer?.cancel();

    final result = {
      'earnings': _earnings,
      'trips': _trips,
      'hours': _online.inMinutes / 60.0,
      'stillOnline': false,
    };
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop<Map<String, dynamic>>(result);
      return;
    }
    // Some flows open DriverOnlineScreen as root (pushAndRemoveUntil).
    // In that case, popping causes a black screen. Always route to Home.
    nav.pushAndRemoveUntil(
      smoothFadeRoute(const DriverHomeScreen(returnFromTrip: false)),
      (_) => false,
    );
  }
  
  void _pauseAvailability() {
    HapticFeedback.mediumImpact();
    _setState(() => _isPaused = true);
    
    // Stop polling for offers while paused
    _pollT?.cancel();
    
    // Show pause dialog with timer options
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('⏸️ Paused'),
          content: const Text(
            'You are paused and won\'t receive new trip requests.\n\nHow long do you want to pause?',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _resumeFromPause();
              },
              child: Text(S.of(context).resumeNow),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _scheduleResume(minutes: 15);
                _snack('⏸️ Paused for 15 minutes');
              },
              child: Text(S.of(context).fifteenMin),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _scheduleResume(minutes: 30);
                _snack('⏸️ Paused for 30 minutes');
              },
              child: Text(S.of(context).thirtyMin),
            ),
          ],
        );
      },
    );
  }
  
  void _resumeFromPause() {
    _setState(() => _isPaused = false);
    _pauseTimer?.cancel();
    _startPolling(); // Resume polling
    _snack('▶️ Back online - receiving trip requests');
  }
  
  void _scheduleResume({required int minutes}) {
    _pauseTimer?.cancel();
    _pauseTimer = Timer(Duration(minutes: minutes), () {
      if (mounted && _isPaused) {
        _resumeFromPause();
      }
    });
  }

  /// Go back to home without going offline — driver stays connected.
  void _goBack() {
    HapticFeedback.lightImpact();
    final result = <String, dynamic>{
      'earnings': _earnings,
      'trips': _trips,
      'hours': _online.inMinutes / 60.0,
      'stillOnline': true,
    };
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop<Map<String, dynamic>>(result);
      return;
    }
    // Some flows open DriverOnlineScreen as root (pushAndRemoveUntil after
    // rating). In that case, popping causes a black screen. Route to Home.
    nav.pushAndRemoveUntil(
      smoothFadeRoute(const DriverHomeScreen(returnFromTrip: true)),
      (_) => false,
    );
  }

  Future<void> _cancel() async {
    _navService.stopNavigation();
    _navState = null;
    _currentNavRoute = null;
    _navTimer?.cancel();
    final tripId = _tripId;
    if (tripId != null) {
      try {
        await ApiService.updateTripStatus(tripId: tripId, status: 'canceled');
      } catch (_) {}
      // Immediate Firestore sync so rider listener reacts in real time.
      await TripFirestoreService.syncTripCancelled(
        'sql_$tripId',
        cancelledBy: 'driver',
        cancellationReason: 'driver_cancelled',
        reason: 'Driver cancelled',
      );
    }
    _setState(() {
      _phase = _Phase.searching;
      _tripId = null;
      _currentOfferId = null;
      _routePts = [];
      _pendingOffers = [];
    });
    _syncSearchPulse();
    _clearAllAnnotations();
    if (_pos != null) _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
    _startPolling();
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  NAV — Real GPS drives the navigation now.
  //  _simNav is kept as a no-op for backward compat.
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _simNav() {
    // No-op: real GPS position stream handles all nav updates
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  DIRECTIONS API
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Future<void> _drawRoute(LatLng o, LatLng d, String id, Color c) async {
    debugPrint(
      'ðŸ—ºï¸ _drawRoute: ${o.latitude},${o.longitude} â†’ ${d.latitude},${d.longitude}',
    );

    // Try Google Directions API with multiple parameter variants
    final variants = <Map<String, String>>[
      {
        'origin': '${o.latitude},${o.longitude}',
        'destination': '${d.latitude},${d.longitude}',
        'key': ApiKeys.webServices,
        'mode': 'driving',
        'alternatives': 'true',
      },
      {
        'origin': '${o.latitude},${o.longitude}',
        'destination': '${d.latitude},${d.longitude}',
        'key': ApiKeys.webServices,
        'mode': 'driving',
      },
    ];

    for (final query in variants) {
      try {
        final uri = Uri.https(
          'maps.googleapis.com',
          '/maps/api/directions/json',
          query,
        );
        final res = await http.get(uri).timeout(const Duration(seconds: 10));
        debugPrint('ðŸ—ºï¸ Directions API status: ${res.statusCode}');
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          debugPrint(
            'ðŸ—ºï¸ Directions API response status: ${data['status']}',
          );
          if (data['status'] == 'OK' && (data['routes'] as List).isNotEmpty) {
            final route = data['routes'][0];
            final pts = _decodePoly(
              route['overview_polyline']['points'] as String,
            );
            final leg = route['legs'][0];
            final steps = leg['steps'] as List;
            String instr = mounted ? S.of(context).headToDestination : '';
            if (steps.isNotEmpty) {
              instr = (steps[0]['html_instructions']?.toString() ?? '')
                  .replaceAll(RegExp(r'<[^>]*>'), '');
            }

            // Parse turn-by-turn NavRoute for live navigation
            final navRoute = NavigationService.fromDirectionsResponse(data);
            if (navRoute != null) {
              _currentNavRoute = navRoute;
              _navService.startNavigation(navRoute);
              _rerouteCount = 0;
              debugPrint('Nav: ${navRoute.steps.length} steps parsed');
            }

            debugPrint('ðŸ—ºï¸ Google route OK: ${pts.length} points');
            _setState(() {
              _routePts = pts;
              _navDist = (leg['distance']['value'] as int) / 1609.34;
              _navEta = ((leg['duration']['value'] as int) / 60).ceil();
              _navInstruct = instr;
            });
            _setRouteAnnotation(pts, c);
            return;
          }
        }
      } catch (e) {
        debugPrint('ðŸ—ºï¸ Google Directions attempt failed: $e');
      }
    }

    // Fallback: OSRM (free, no API key needed)
    debugPrint('ðŸ—ºï¸ Trying OSRM fallback...');
    try {
      final path =
          '/route/v1/driving/${o.longitude},${o.latitude};${d.longitude},${d.latitude}';
      final uri = Uri.https('router.project-osrm.org', path, {
        'overview': 'full',
        'steps': 'true',
        'geometries': 'polyline',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      final data = jsonDecode(res.body);
      if (data is Map<String, dynamic> &&
          data['code']?.toString().toUpperCase() == 'OK') {
        final routes = data['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          final route = routes[0];
          final pts = _decodePoly(route['geometry'] as String);
          final distM = (route['distance'] as num?)?.toInt() ?? 0;
          final durS = (route['duration'] as num?)?.toInt() ?? 0;
          String instr = mounted ? S.of(context).headToDestination : '';
          final legs = route['legs'] as List?;
          if (legs != null && legs.isNotEmpty) {
            final rawSteps = legs[0]['steps'] as List? ?? [];
            if (rawSteps.isNotEmpty) {
              instr = rawSteps[0]['name']?.toString().isNotEmpty == true
                  ? 'Head on ${rawSteps[0]['name']}'
                  : instr;
            }
            // Build NavRoute from OSRM steps for turn-by-turn instructions
            final navSteps = <NavStep>[];
            for (int i = 0; i < rawSteps.length - 1; i++) {
              final step = rawSteps[i] as Map<String, dynamic>;
              final nextStep = rawSteps[i + 1] as Map<String, dynamic>;
              final mv = step['maneuver'] as Map<String, dynamic>? ?? {};
              final type = mv['type']?.toString() ?? 'straight';
              final mod = mv['modifier']?.toString() ?? '';
              String maneuver;
              if (type == 'turn') {
                if (mod == 'left') {
                  maneuver = 'turn-left';
                } else if (mod == 'right') {
                  maneuver = 'turn-right';
                } else if (mod == 'slight left') {
                  maneuver = 'turn-slight-left';
                } else if (mod == 'slight right') {
                  maneuver = 'turn-slight-right';
                } else if (mod == 'sharp left') {
                  maneuver = 'turn-sharp-left';
                } else if (mod == 'sharp right') {
                  maneuver = 'turn-sharp-right';
                } else {
                  maneuver = 'straight';
                }
              } else if (type == 'merge') {
                maneuver = 'merge';
              } else if (type == 'fork') {
                maneuver = mod.contains('left') ? 'fork-left' : 'fork-right';
              } else if (type == 'ramp') {
                maneuver = mod.contains('left') ? 'ramp-left' : 'ramp-right';
              } else {
                maneuver = 'straight';
              }
              final locArr = mv['location'] as List? ?? [0, 0];
              final stepLoc = LatLng(
                (locArr[1] as num).toDouble(),
                (locArr[0] as num).toDouble(),
              );
              final nMv = nextStep['maneuver'] as Map<String, dynamic>? ?? {};
              final nArr = nMv['location'] as List? ?? [0, 0];
              final nextLoc = LatLng(
                (nArr[1] as num).toDouble(),
                (nArr[0] as num).toDouble(),
              );
              final sName = step['name']?.toString() ?? '';
              final sDist = (step['distance'] as num?)?.toDouble() ?? 0;
              final sDur = (step['duration'] as num?)?.toDouble() ?? 0;
              String instrText;
              if (type == 'depart') {
                instrText = sName.isNotEmpty ? 'Head on $sName' : 'Depart';
              } else if (type == 'arrive') {
                instrText = 'Arrive at destination';
              } else if (type == 'turn') {
                instrText = 'Turn $mod${sName.isNotEmpty ? ' on $sName' : ''}';
              } else if (type == 'merge') {
                instrText = 'Merge${sName.isNotEmpty ? ' onto $sName' : ''}';
              } else if (type == 'fork') {
                instrText = 'Keep $mod at fork${sName.isNotEmpty ? ' onto $sName' : ''}';
              } else if (type == 'ramp') {
                instrText = 'Take ramp${sName.isNotEmpty ? ' to $sName' : ''}';
              } else {
                instrText = sName.isNotEmpty ? 'Continue on $sName' : 'Continue';
              }
              List<LatLng> stepPoly = [stepLoc, nextLoc];
              final stepGeo = step['geometry'];
              if (stepGeo is String && stepGeo.isNotEmpty) {
                final dec = _decodePoly(stepGeo);
                if (dec.isNotEmpty) stepPoly = dec;
              }
              navSteps.add(NavStep(
                instruction: instrText,
                maneuver: maneuver,
                distanceMeters: sDist,
                durationSeconds: sDur.toInt(),
                streetName: sName,
                startLocation: stepLoc,
                endLocation: nextLoc,
                polyline: stepPoly,
              ));
            }
            if (navSteps.isNotEmpty) {
              final navRoute = NavRoute(
                overviewPolyline: pts,
                steps: navSteps,
                totalDistanceMeters: distM.toDouble(),
                totalDurationSeconds: durS,
                startAddress: '',
                endAddress: '',
              );
              _currentNavRoute = navRoute;
              _navService.startNavigation(navRoute);
              _rerouteCount = 0;
              instr = navSteps.first.instruction;
              debugPrint('OSRM Nav: ${navSteps.length} steps parsed');
            }
          }
          debugPrint('ðŸ—ºï¸ OSRM route OK: ${pts.length} points');
          _setState(() {
            _routePts = pts;
            _navDist = distM / 1609.34;
            _navEta = (durS / 60).ceil().clamp(1, 999);
            _navInstruct = instr;
          });
          _setRouteAnnotation(pts, c);
          return;
        }
      }
    } catch (e) {
      debugPrint('ðŸ—ºï¸ OSRM fallback failed: $e');
    }

    // Last resort: straight line
    debugPrint('ðŸ—ºï¸ Using straight-line fallback');
    _fallbackRoute(o, d, id, c);
  }

  List<LatLng> _decodePoly(String enc) {
    final pts = <LatLng>[];
    int i = 0, lat = 0, lng = 0;
    while (i < enc.length) {
      int s = 0, r = 0, b;
      do {
        b = enc.codeUnitAt(i++) - 63;
        r |= (b & 0x1F) << s;
        s += 5;
      } while (b >= 0x20);
      lat += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      s = 0;
      r = 0;
      do {
        b = enc.codeUnitAt(i++) - 63;
        r |= (b & 0x1F) << s;
        s += 5;
      } while (b >= 0x20);
      lng += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      pts.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return pts;
  }

  void _fallbackRoute(LatLng a, LatLng b, String id, Color c) {
    final pts = List.generate(21, (i) {
      final t = i / 20;
      return LatLng(
        a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t,
      );
    });
    _setState(() {
      _routePts = pts;
    });
    _setRouteAnnotation(pts, c);
  }
}
