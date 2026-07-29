part of 'driver_online_screen.dart';

// ══════════════════════════════════════════════════════════════
//  CONTROLLER — boot, GPS, polling, offers, navigation, trips
// ══════════════════════════════════════════════════════════════

// ── Global guards against polling storm (P1 fix) ──
// These survive widget rebuilds and prevent multiple DriverOnlineScreen
// instances from creating overlapping poll timers.
int _driverOnlinePollingGen = 0;
bool _driverOnlinePollLock = false;
DateTime? _driverOnlineLastStartPolling;

final _htmlTagRe = RegExp(r'<[^>]*>');

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
    // Fire driver-ID resolution in background — don't block boot.
    // _verifyAndGoOnline retries if this hasn't resolved yet.
    unawaited(Future.microtask(() async {
      try {
        final id = await ApiService.getCurrentUserId();
        if (id != null) {
          _driverId = id;
          debugPrint('Got driverId');
        }
      } catch (e) {
        debugPrint('getCurrentUserId failed: $e');
      }
    }));

    // Let the page transition animation settle before starting
    // background services (400ms transition + small buffer).
    // Use addPostFrameCallback so we don't block the first build frame.
    // Start everything immediately — no artificial delays
    // Stagger service initialization to prevent UI thread saturation.
    // Each service starts in its own microtask so the framework can
    // pump frames between them — eliminates the 1s freeze on entry.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _startClock();
      await Future.microtask(() => _startPolling());
      if (!mounted) return;
      await Future.microtask(() => _startPosStream());
      if (!mounted) return;
      await Future.microtask(() => _loadAllEarnings());
      if (!mounted) return;
      await Future.microtask(() => _startEarningsRefresh());
      if (!mounted) return;
      await Future.microtask(() => _startScheduledPoll());
      if (!mounted) return;
      // Fire-and-forget: these must not block the UI thread
      unawaited(_locate());
      unawaited(Future.microtask(_verifyAndGoOnline));
    });

    // Listen for network recovery — proactively reconnect SSE + re-register
    // online status when connectivity returns after a drop.
    _networkListener = () {
      if (!mounted) return;
      final online = NetworkService().isOnline;
      if (online && _phase == _Phase.searching && !_sseActive) {
        debugPrint('[DriverOnline] Network recovered — reconnecting SSE + re-registering online');
        _connectSse();
        _goOnlineBackend();
      }
    };
    NetworkService().onlineNotifier.addListener(_networkListener!);

    // Build vehicle icons immediately — if there's jank, fix the animation, don't delay
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _buildVehicleIcons();
    });

    // Pre-cache map tiles in background (fire-and-forget)
    if (_pos != null) {
      unawaited(MapCacheService().precacheArea(
        regionId: 'driver_area_${_driverId ?? 0}',
        lat: _pos!.latitude,
        lng: _pos!.longitude,
        minZoom: 10,
        maxZoom: 16,
        radiusKm: 5.0,
      ));
    }
  }

  /// Background verification + go-online — never blocks boot.
  Future<void> _verifyAndGoOnline() async {
    // Signal UI immediately that we're going online — don't wait for any API
    _setState(() => _isGoingOnline = true);

    // Retry driver ID if first attempt failed
    if (_driverId == null) {
      for (int attempt = 1; attempt <= 2; attempt++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        try {
          final id = await ApiService.getCurrentUserId();
          if (!mounted) return;
          if (id != null) {
            _driverId = id;
            debugPrint('✅ Got driverId on retry $attempt');
            // Reconnect SSE now that we have an ID
            _connectSse();
            _startPosStream();
            break;
          }
        } catch (_) {}
      }
    }
    if (!mounted) {
      _setState(() => _isGoingOnline = false);
      return;
    }
    await _verifyDriverApproval();
    if (!mounted) {
      _setState(() => _isGoingOnline = false);
      return;
    }
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
    ]);
    _suvIconBytes = results[0] as Uint8List?;
    _sedanIconBytes = results[1] as Uint8List?;
    _arrowIconBytes = _suvIconBytes;
    _navCarSprites = null;
    _navCarIconBytes = results[2] as Uint8List?;
    // results[3] is void (_loadDriverPhoto sets _driverPhotoImage internally)
    _goldPinBytes = results[4] as Uint8List?;
    await _goldDot.build(this, () { if (mounted) _updateDriverAnnotation(); });
    if (!mounted) return;
    // The dot image is what _updateDriverAnnotation() gates on — every call
    // before this point bailed out with no bytes. Draw it now instead of
    // waiting for the next GPS tick: a driver who goes online standing still
    // never gets one, so the dot would simply never appear.
    _updateDriverAnnotation();
    _startDotWatchdog();
    _setState(() {});
  }

  /// Low-frequency safety net for the driver dot (0.5 Hz).
  ///
  /// The dot is normally redrawn by [_onSmoothTick], but that ticker parks
  /// itself once the driver reaches the target position, so a stationary
  /// driver gets no redraws at all. Anything that leaves the annotation
  /// missing or half-scaled — late icon bytes, a dropped pop-scale flush, a
  /// map recreated on resume — would then stay broken until they drove off.
  void _startDotWatchdog() {
    _dotWatchdog?.cancel();
    _dotWatchdog = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted) return;
      if (_smoothTicker?.isTicking ?? false) return; // ticker has it covered
      // The dot bitmap is rasterised once. That can fail (GPU context lost
      // while backgrounded, OOM), and GoldLocationDot then leaves
      // currentBytes null — which makes every draw below a silent no-op
      // forever, since nothing else calls build() again on this screen.
      if (!_goldDot.isReady) {
        await _goldDot.build(this, () { if (mounted) _updateDriverAnnotation(); });
        if (!mounted) return;
      }
      _updateDriverAnnotation();
    });
  }

  /// Download and decode the driver's profile photo for the map marker.
  Future<void> _loadDriverPhoto() async {
    final url = widget.photoUrl;
    if (url == null || url.isEmpty) return;
    try {
      // Hard timeout: this download sits inside the Future.wait() that gates
      // _goldDot.build(), so a stalled request would keep the driver dot off
      // the map for as long as the socket hangs.
      final resp = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 6));
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

      // Check profile photo — mandatory for drivers
      final photoUrl = (me['photo_url'] ?? me['profile_photo_url'] ?? '').toString();
      final hasPhoto = photoUrl.isNotEmpty &&
          photoUrl != 'null' && photoUrl != 'None' && photoUrl != 'none';

      // Check user-level approval
      final userApproved = (bgStatus == 'clear' || bgStatus == 'none') &&
          (verStatus == 'approved' || verStatus == 'none');

      // If driver is already approved, only check photo — don't re-verify
      // vehicle docs (those were checked during approval process).
      if (userApproved && hasPhoto) {
        _approvalGatePassed = true;
        return;
      }

      // Not yet approved — check vehicle docs for pending applicants
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

      if (userApproved && vehicleDocsOk && hasPhoto) {
        _approvalGatePassed = true;
        return;
      }

      _approvalGatePassed = false;
      if (!mounted) return;
      String title;
      String message;

      if (!hasPhoto) {
        title = 'Profile Photo Required';
        message = 'You must add a profile photo before going online. Riders need to recognize you.\n\nGo to Profile > add your photo.';
      } else if (!userApproved) {
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
              child: Text(S.of(context).ok, style: const TextStyle(color: Color(0xFFE8C547))),
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
    // _isGoingOnline is already set to true by _verifyAndGoOnline() before
    // calling this method. The guard below would incorrectly skip if it were
    // still true — remove it since the caller already handles deduplication.
    if (_driverId == null) {
      debugPrint('⚠️ _goOnlineBackend: _driverId is null, skipping');
      _setState(() => _isGoingOnline = false);
      return;
    }
    debugPrint(
      '🟢 Going online: lat=${_pos?.latitude} lng=${_pos?.longitude}',
    );
    if (!_approvalGatePassed) {
      debugPrint('_goOnlineBackend: approval gate not passed, skipping');
      _setState(() => _isGoingOnline = false);
      return;
    }
    if (_driverId == null || _pos == null) {
      debugPrint('⚠️ _goOnlineBackend: ${_driverId == null ? "driverId" : "GPS"} not ready yet, retrying in 3s');
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && _phase == _Phase.searching) _goOnlineBackend();
      });
      return;
    }
    // _isGoingOnline is already true from _verifyAndGoOnline; keep it true
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
          _isGoingOnline = false;
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
          _isGoingOnline = false;
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
  //  BACKGROUND HEARTBEAT — keeps driver online when app is backgrounded
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _startBackgroundHeartbeat() {
    _bgHeartbeatTimer?.cancel();
    // Send heartbeat every 30s to keep driver "online" in backend.
    // This prevents the backend from marking the driver offline due to
    // inactivity while the app is backgrounded.
    _bgHeartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (_driverId == null || _pos == null) return;
      try {
        await ApiService.updateDriverLocation(
          driverId: _driverId!,
          lat: _pos!.latitude,
          lng: _pos!.longitude,
          isOnline: true,
        );
        debugPrint('[DriverOnline] Background heartbeat sent');
      } catch (e) {
        debugPrint('[DriverOnline] Background heartbeat failed: $e');
      }
    });
  }

  void _stopBackgroundHeartbeat() {
    _bgHeartbeatTimer?.cancel();
    _bgHeartbeatTimer = null;
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  DRIVER POSITION STREAM (smooth movement on map)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _startPosStream() {
    // Prevent duplicate GPS streams — cancel existing before creating new
    _posStream?.cancel();
    _posStream = null;

    // FIX: Ensure Socket.io is initialized so the driver can send GPS
    // via Socket.io (primary channel). Previously init() was only called
    // in main.dart or by the rider — if it failed or the socket got
    // disposed, the driver had no way to reconnect.
    if (!SocketService.isConnected && !SocketService.isConnecting) {
      unawaited(SocketService.init());
    }

    // Start GpsService for Firebase RTDB uploads + presence
    if (_driverId != null) {
      _gpsService.startTracking(_driverId.toString());
    }

    _posStream =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            // distanceFilter: 2 -> fixes every 2 meters.
            // SmoothMotion still glides smoothly. Balance accuracy/battery.
            distanceFilter: 2,
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
    HapticService.mediumImpact();

    final dest = _phase == _Phase.enRouteToPickup ? _pickupLL : _dropoffLL;
    final routeId = _phase == _Phase.enRouteToPickup ? 'pickup' : 'trip';
    await _drawRoute(from, dest, routeId, _navyRoute);
    _isRerouting = false;
  }

  void _onNearPickup() {
    if (_nearPickupNotified || _phase != _Phase.enRouteToPickup) return;
    _nearPickupNotified = true;
    HapticService.heavyImpact();
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
    HapticService.heavyImpact();
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
    _motion.setTarget(target.latitude, target.longitude, bearing: heading);
    // Seed _pos on the very first fix so the first render doesn't start
    // from (0, 0) — the ticker fills it in subsequent frames.
    if (_pos == null && _motion.hasPosition) {
      _pos = LatLng(_motion.lat!, _motion.lng!);
      _heading = _motion.bearing;
    }
    // Start the ticker lazily on the first real GPS position so it does not
    // burn CPU during the period before any movement data is available.
    //
    // 2026-04-27 freeze fix: Don't start the 60fps ticker until the page
    // transition (400ms fade+scale) has finished. The ticker hammers the
    // MethodChannel with annotation+camera updates at 60fps, which stacks
    // on top of the route transition animation and causes a 1-2s freeze on
    // mid-range Android devices. We defer by 500ms so the transition owns
    // the UI thread cleanly.
    //
    // The deferral applies to the FIRST start only. Later restarts happen
    // every time the driver pulls away after standing still (the ticker parks
    // itself at the target), and delaying those by half a second is exactly
    // the "dot doesn't follow me" lag — the transition is long gone by then.
    if (!(_smoothTicker?.isTicking ?? false)) {
      if (_smoothTickerStarted) {
        _smoothTicker?.start();
      } else {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && !(_smoothTicker?.isTicking ?? false)) {
            _smoothTickerStarted = true;
            _smoothTicker?.start();
          }
        });
      }
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

  /// Continuous 60fps ticker — Google-Maps-style constant-velocity advance
  /// via [SmoothMotion]. Never resets, never stutters, keeps gliding at the
  /// measured speed between GPS fixes instead of decelerating into a stall.
  void _onSmoothTick(Duration elapsed) {
    if (!mounted || _pos == null) return;
    if (!_motion.hasPosition) return;

    // Frame delta in seconds. Clamp huge gaps (background resume) so we
    // never teleport the marker across several seconds in one step.
    final dtMs = (elapsed - _lastTickElapsed).inMilliseconds.clamp(1, 50);
    _lastTickElapsed = elapsed;
    final dtSec = dtMs / 1000.0;

    _motion.tick(dtSec);
    _pos = LatLng(_motion.lat!, _motion.lng!);
    _heading = _motion.bearing;

    // Unified camera following (single source of truth for all phases)
    // Skip camera control when offer animation is running or route is previewing
    final isNav = _phase == _Phase.enRouteToPickup || _phase == _Phase.inTrip;
    final offerActive = _isCardAnimating || _previewingOffer != null;
    if (_phase == _Phase.searching && !offerActive) {
      // Entry zoom ease: the map opens at zoom 16 (same as home) and
      // glides to the working 15.5 over ~750ms (easeOutCubic) so there
      // is no zoom "pop" when arriving from the home screen.
      double zoom = 15.5;
      if (!_zoomEaseDone) {
        _zoomEaseStartMs ??= elapsed.inMilliseconds;
        final t = ((elapsed.inMilliseconds - _zoomEaseStartMs!) / 750.0)
            .clamp(0.0, 1.0);
        final e = 1.0 - math.pow(1.0 - t, 3).toDouble();
        zoom = 16.0 - 0.5 * e;
        if (t >= 1.0) _zoomEaseDone = true;
      }
      // Smooth camera follow at 60fps — setCamera (instant) so the camera
      // glides with the interpolated dot position frame-by-frame.
      _map?.setCamera(
        mapbox.CameraOptions(
          center: mapbox.Point(
              coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),
          zoom: zoom,
          bearing: 0,
          pitch: 0,
        ),
      );
    } else if (isNav && _cameraFollowing) {
      // Nav camera follow at 60fps — setCamera (instant) so the car stays
      // glued to center without jumps. The smoothness comes from _motion.tick()
      // running every frame, not from easing animations.
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

    // Annotation update every frame — write freshest geometry in-memory
    // (cheap), then flush to Mapbox. The annotation follows the dot exactly.
    _updateDriverAnnotation();

    // Stop ticker when parked on the target — saves CPU when idle/stationary.
    // The ticker restarts automatically on the next _smoothMoveTo().
    if (_motion.isAtTarget) {
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
    // ── Debounce: ignore rapid-fire calls within 1s ──
    final now = DateTime.now();
    if (_driverOnlineLastStartPolling != null &&
        now.difference(_driverOnlineLastStartPolling!).inMilliseconds < 1000) {
      debugPrint('[DriverOnline] _startPolling debounced (called within 1s)');
      return;
    }
    _driverOnlineLastStartPolling = now;

    _pollT?.cancel();
    _offerSseSub?.cancel();
    _sseReconnectTimer?.cancel();
    _sseActive = false;

    _connectSse();

    // Polling fallback — only fires when SSE is DOWN to save battery.
    // Polls /dispatch/driver/pending every 5s; skipped entirely while SSE is active.
    final myGen = ++_driverOnlinePollingGen;
    _pollT = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || _phase != _Phase.searching) return;
      if (_sseActive) return; // SSE handles it — skip polling entirely
      if (myGen != _driverOnlinePollingGen) {
        debugPrint('[DriverOnline] stale poll timer skipped (gen $myGen != $_driverOnlinePollingGen)');
        return;
      }
      debugPrint('[DriverOnline] SSE down — polling /dispatch/driver/pending');
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
  ///
  /// C4 fix: this used to be invoked from 3 different places (go-online,
  /// network change, onError/onDone) which could leave two streams active
  /// at once if timing was unlucky — both would deliver the same offer and
  /// the driver could double-accept. We now bump `_currentSseGeneration`
  /// on every reconnect and drop any event whose captured generation no
  /// longer matches the current one.
  void _connectSse() {
    _offerSseSub?.cancel();
    _sseReconnectTimer?.cancel();
    final driverId = _driverId;
    if (driverId == null || !mounted) return;

    final int myGeneration = ++_currentSseGeneration;

    void scheduleReconnect(String reason) {
      // Only the CURRENT generation is allowed to schedule the next reconnect.
      // Events from stale generations are dropped silently.
      if (myGeneration != _currentSseGeneration) return;
      debugPrint('[DriverOnline] SSE $reason — falling back to polling, reconnecting in 500ms');
      _sseActive = false;
      if (mounted && _phase == _Phase.searching) {
        _sseReconnectTimer = Timer(const Duration(milliseconds: 500), _connectSse);
      }
    }

    _offerSseSub = ApiService.streamDriverOffers(driverId).listen(
      (offers) {
        // Drop events from stale generations — another _connectSse has
        // already superseded this listener.
        if (myGeneration != _currentSseGeneration) {
          debugPrint(
            '[DriverOnline] SSE stale event dropped (gen $myGeneration < $_currentSseGeneration)',
          );
          return;
        }
        if (!_sseActive) {
          debugPrint('[DriverOnline] SSE reconnected — stopping polling fallback');
        }
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
    int? toInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is double) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    // Filter out locally rejected AND already-accepted offers
    var filtered = offers.where((o) {
      final oid = toInt(o['offer_id']);
      if (oid == null) return true;
      if (_rejectedOfferIds.contains(oid)) return false;
      if (_acceptedOfferIds.contains(oid)) {
        debugPrint('[DriverOnline] already-accepted offer dropped: $oid');
        return false;
      }
      return true;
    }).toList();

    // Deduplicate by offer_id — SSE + polling can receive the same offer
    final seenIds = <int>{};
    filtered = filtered.where((o) {
      final oid = toInt(o['offer_id']);
      if (oid == null) return true; // keep offers without id
      if (seenIds.contains(oid)) {
        debugPrint('[DriverOnline] duplicate offer dropped: $oid');
        return false;
      }
      seenIds.add(oid);
      return true;
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
      // Escalating haptic burst — 3 heavy pulses spaced 160ms so the driver
      // can't miss the offer even with the phone flat on a table.
      HapticService.heavyImpact();
      Future.delayed(const Duration(milliseconds: 160), () {
        if (!mounted) return;
        HapticService.heavyImpact();
      });
      Future.delayed(const Duration(milliseconds: 320), () {
        if (!mounted) return;
        HapticService.heavyImpact();
      });
      final firstOffer = filtered.first;
      if (_appInForeground) {
        // Foreground: in-app sound + haptic is sufficient. The offer card
        // UI is already visible. Don't show a local OS notification — the
        // backend sends FCM push which the OS shows when backgrounded.
        NotificationService.playOfferSound();
      } else {
        // Background: show the local notification with fullscreen intent
        // so the driver sees it even with the phone locked.
        NotificationService.showOfferNotification(
          title: S.of(context).newRideOffer,
          body: '',
          offerId: (firstOffer['offer_id'] as num? ?? 0).toInt(),
          payload: 'trip_offer',
          appInForeground: false,
        );
      }
    }

    _setState(() {
      _pendingOffers = filtered;
      if (filtered.isNotEmpty) {
        _currentOfferIndex = _currentOfferIndex.clamp(0, filtered.length - 1);
      }
      if (filtered.isNotEmpty && !hadOffers) _hideFindingBar = true;
      if (filtered.isEmpty && hadOffers) _hideFindingBar = false;
    });
    // Routes are still pre-fetched so a tap draws instantly, but nothing is
    // drawn on arrival: an incoming offer shows the card and only the card.
    // Drawing the route unasked hijacked the map the moment an offer landed,
    // animating a line and pins over whatever the driver was looking at. The
    // route now appears when the driver taps the card — see _onOfferCardTap,
    // already wired at driver_online_widgets.dart:638.
    _preFetchOfferRoutes(filtered);
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
          debugPrint('âœ… Recovered driverId during polling');
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
    debugPrint('[DriverOnline] _acceptOffer called — map=$_map, phase=$_phase');
    debugPrint('[DriverOnline] offer data: ${r.keys.toList()}');
    // Prevent double-tap
    final oid = (r['offer_id'] ?? r['id'] ?? '').toString();
    if (_offerAcceptState != _OfferAcceptState.normal) {
      debugPrint('[DriverOnline] _acceptOffer blocked — state=$_offerAcceptState');
      return;
    }

    int? toInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is double) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    final offerId = toInt(r['offer_id']);
    final tripId = toInt(r['trip_id']) ?? toInt(r['id']);
    debugPrint('[DriverOnline] parsed offerId=$offerId, tripId=$tripId');

    // Guard: driverId must be resolved before accepting
    if (_driverId == null) {
      debugPrint('[DriverOnline] _driverId is null — attempting recovery...');
      try {
        final id = await ApiService.getCurrentUserId();
        if (id != null) {
          _driverId = id;
          debugPrint('[DriverOnline] Recovered driverId');
        }
      } catch (e) {
        debugPrint('[DriverOnline] Failed to recover driverId: $e');
      }
      if (_driverId == null) {
        debugPrint('[DriverOnline] _driverId still null after recovery — aborting accept');
        _setState(() {
          _offerAcceptState = _OfferAcceptState.normal;
          _acceptingCardId = null;
        });
        _snack('Unable to accept — please try again.');
        return;
      }
    }

    // C5 fix: idempotent guard keyed on offerId. If the same offer is
    // delivered twice by the SSE layer (or re-emitted from a stale stream
    // that slipped past the generation check in _connectSse), the second
    // call here is dropped silently instead of firing a second backend
    // accept request.
    if (offerId != null) {
      if (_acceptedOfferIds.contains(offerId)) {
        debugPrint('[DriverOnline] duplicate accept dropped for offer=$offerId');
        return;
      }
      _acceptedOfferIds.add(offerId);
    }

    HapticService.heavyImpact();

    // Block further taps — show loading state on the button
    _setState(() {
      _offerAcceptState = _OfferAcceptState.routing;
      _acceptingCardId = oid;
    });

    // True once DriverTripAcceptScreen owns the trip. Guards the outer
    // catch below from handing back a trip that is being driven for real.
    bool handedOff = false;

    try {
      debugPrint('[DriverOnline] ▶ STEP 1: creating acceptFuture');
      final acceptFuture = (() async {
        if (offerId != null && _driverId != null) {
          debugPrint('[DriverOnline] ▶ STEP 1a: calling acceptRideOffer(offerId=$offerId)');
          await ApiService.acceptRideOffer(
            offerId: offerId,
            driverId: _driverId!,
          );
          debugPrint('[DriverOnline] ▶ STEP 1b: acceptRideOffer SUCCESS');
          return true;
        }
        if (tripId != null && _driverId != null) {
          debugPrint('[DriverOnline] ▶ STEP 1a: calling acceptTrip(tripId=$tripId)');
          await ApiService.acceptTrip(tripId: tripId, driverId: _driverId!);
          debugPrint('[DriverOnline] ▶ STEP 1b: acceptTrip SUCCESS');
          return true;
        }
        debugPrint('[DriverOnline] ▶ STEP 1a: NO offerId or tripId — returning false');
        return false;
      })();

      debugPrint('[DriverOnline] ▶ STEP 2: rejecting other offers');
      // Reject all other pending offers silently
      for (final other in _pendingOffers) {
        final otherId = (other['offer_id'] as num?)?.toInt();
        if (otherId != null && otherId != offerId && _driverId != null) {
          ApiService.rejectRideOffer(
            offerId: otherId,
            driverId: _driverId!,
          ).catchError((_) => <String, dynamic>{});
        }
      }

      debugPrint('[DriverOnline] ▶ STEP 3: populating trip data');
      // Populate active trip data from the accepted offer.
      //
      // Every field is coerced, never cast. A hard `as String` on a payload
      // field throws a TypeError the moment the backend sends a number (or
      // anything else) where a string was expected, and the only thing the
      // driver sees is "Error accepting offer" — with the trip already
      // assigned to them server-side. A wrong-looking address is survivable;
      // losing the accept is not.
      String str(dynamic v, String fallback) {
        if (v == null) return fallback;
        final s = v.toString().trim();
        return s.isEmpty ? fallback : s;
      }

      final name = str(r['rider_name'], 'Rider');
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
      // Start the top-level cancel watcher as soon as we know the trip id.
      // It lives on this screen, so it survives the handoff to
      // DriverTripAcceptScreen and every transition after it — the only
      // sources of truth for remote cancellation are Firestore and this
      // watcher.
      if (tripId != null) {
        // Firestore access can throw synchronously when the app has no
        // Firebase instance. Losing the cancel watcher is bad; losing the
        // accept because of it is worse.
        try {
          _startActiveTripCancelWatcher(tripId);
        } catch (e) {
          debugPrint('[DriverOnline] cancel watcher failed to arm: $e');
        }
      }
      _riderName = name;
      _riderInit = name.isNotEmpty ? name[0].toUpperCase() : '?';
      _riderPhotoUrl = _normalizePhotoUrl(r['rider_photo_url'] ?? r['photo_url'] ?? '');
      _riderPhone = str(r['rider_phone'], '');
      _riderId = (r['rider_id'] ?? '').toString();
      _pickupAddr = str(r['pickup_address'], 'Pickup');
      _dropoffAddr = str(r['dropoff_address'], 'Drop-off');
      _fare = (r['fare'] as num?)?.toDouble() ?? 0;
      _vehicleType = _mapRideType(str(r['vehicle_type'], 'Comfort'));
      _distToPickup = _pos != null ? _hav(_pos!, _pickupLL) : 0.0;
      _etaToPickup = (_distToPickup * 1000 / 17.88 / 60).ceil().clamp(1, 99);
      _tripDist = _hav(_pickupLL, _dropoffLL);
      _tripEta = (_tripDist * 1000 / 17.88 / 60).ceil().clamp(1, 99);

      // ── Extract cached route BEFORE clearing cache ──
      final cachedRouteData = _routeCache[oid];
      final preRoutePoints = cachedRouteData?.segOne;

      // FIX: Cancelar el stream de GPS de DriverOnlineScreen antes de navegar
      // para evitar doble stream cuando DriverTripAcceptScreen cree el suyo.
      _posStream?.cancel();
      _posStream = null;

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
      debugPrint('[DriverOnline] ▶ STEP 4: clearing annotations');
      try {
        await _clearAllAnnotations();
      } catch (e) {
        debugPrint('[DriverOnline] _clearAllAnnotations failed during accept: $e');
      }
      if (_pos != null) {
        try {
          _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
        } catch (e) {
          debugPrint('[DriverOnline] _animateToPosition failed during accept: $e');
        }
      }

      // ── Reset offer state and navigate to full-screen accepted screen ──
      _tappedCardIds.clear();
      _lastAutoTriggeredOfferId = null;
      if (mounted) {
        _setState(() {
          _offerAcceptState = _OfferAcceptState.normal;
          _acceptingCardId = null;
        });
      }

      debugPrint('[DriverOnline] ▶ STEP 5: writing to Firestore');
      // Write accepted status to Firestore immediately — bypasses the 2-second
      // backend→Firestore sync delay so the rider's listener fires instantly.
      if (tripId != null) {
        String? driverFirstName;
        String? driverLastName;
        String? driverPhone;
        try {
          final driverUser = await UserSession.getUser();
          driverFirstName = driverUser?['firstName']?.toString();
          driverLastName = driverUser?['lastName']?.toString();
          driverPhone = driverUser?['phone']?.toString();
        } catch (e) {
          debugPrint('[DriverOnline] UserSession.getUser() failed during accept: $e');
        }
        final fullName = '${driverFirstName ?? ''} ${driverLastName ?? ''}'.trim();
        final fsDocId = 'sql_$tripId';
        // This write is an accelerator, not a requirement: the backend
        // mirrors the same status a couple of seconds later. `.catchError`
        // only covers the async failure — `FirebaseFirestore.instance`
        // itself throws synchronously when the app has no Firebase (e.g.
        // `[core/no-app]`), and that escaped all the way to the generic
        // "Error accepting offer" toast while the backend had already
        // assigned the trip. Never let it kill the accept.
        try {
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
              'driver_phone': driverPhone ?? '',
              'driverPhone': driverPhone ?? '',
              'driver_photo_url': widget.photoUrl ?? _driverPhotoUrl ?? '',
              'driverPhotoUrl': widget.photoUrl ?? _driverPhotoUrl ?? '',
              'acceptedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true)).catchError((_) {}),
          );
        } catch (e) {
          debugPrint('[DriverOnline] optimistic Firestore write failed: $e');
        }
      }

      if (!mounted) {
        debugPrint('[DriverOnline] _acceptOffer: widget unmounted before nav — aborting');
        return;
      }
      debugPrint('[DriverOnline] ▶ STEP 6: showing accepted celebration — tripId=$tripId, offerId=$offerId');
      final acceptedTripId = tripId ?? offerId ?? 0;
      final riderPhotoUrl = _normalizePhotoUrl(r['rider_photo_url'] ?? r['photo_url'] ?? '');
      final riderRating   = (r['rider_rating']   as num?)?.toDouble() ?? 0;
      // Use the backend's rider_is_new flag as the source of truth — it now
      // reflects rider_rides_count == 0 (first request ever), not just
      // "has never been rated".
      final riderIsNew = r['rider_is_new'] == true;
      final riderInit     = name.isNotEmpty ? name[0].toUpperCase() : '?';

      // ── SINGLE CANVAS ──
      // The celebration is an overlay on the map this screen already owns.
      // It used to be TripAcceptedScreen, a pushed route carrying its own
      // MapWidget, so every accept lit up a second native Mapbox surface —
      // two GL contexts and two tile caches — on top of this one. That is
      // the crash the driver hit right after accepting. Same reason the
      // rider flow was rebuilt around one shared canvas.
      _setState(() {
        _acceptedOverlay = _AcceptedOverlayData(
          riderName:      name,
          riderInitials:  riderInit,
          riderPhotoUrl:  riderPhotoUrl.isNotEmpty ? riderPhotoUrl : null,
          riderRating:    riderRating,
          riderIsNew:     riderIsNew,
          riderId:        int.tryParse(_riderId),
          pickupAddress:  _pickupAddr,
          distToPickupKm: _distToPickup,
          etaMinutes:     _etaToPickup,
        );
      });
      // Camera + route paint onto the existing canvas. Not awaited: the
      // celebration clock must not hang on a Directions API call.
      unawaited(_paintAcceptedRoute(preRoutePoints));
      final celebration = Future<void>.delayed(_acceptedOverlayDuration);

      debugPrint('[DriverOnline] ▶ STEP 7: awaiting acceptFuture');
      try {
        await acceptFuture;
        debugPrint('[DriverOnline] ▶ STEP 7a: acceptFuture completed successfully');
      } catch (e) {
      // ⚠️ CRITICAL phantom-cancel fix:
      //
      // Previously this catch fired _cancel() unconditionally, which sent
      // a PATCH /trips/{id}/status?status=canceled to the server. The
      // problem: the acceptFuture failing doesn't mean the server failed
      // — the 8s HTTP timeout on _client can fire even when the backend
      // successfully processed the accept and marked the trip
      // driver_en_route; only the response got lost / was slow. The
      // driver kept driving to pickup while the rider saw a mysterious
      // "cancelled by operator" dialog because our own client had
      // force-cancelled the trip in the background.
      //
      // Fix: verify the trip's real state server-side before cancelling.
      // If the server says the trip has a driver assigned OR is in
      // driver_en_route/arrived/in_trip, the accept WAS successful —
      // just log the timeout and continue. Only cancel if the server
      // confirms the accept actually did not stick.
      if (!mounted) return;
      debugPrint('[DriverOnline] acceptFuture failed: $e — verifying server state before cancelling');
      bool serverHasTrip = false;
      bool verifyFailed = false;
      final verifyTripId = tripId ?? offerId;
      if (verifyTripId != null) {
        try {
          final serverTrip = await ApiService.getTrip(verifyTripId)
              .timeout(const Duration(seconds: 6));
          final srvStatus = (serverTrip['status'] ?? '').toString().toLowerCase();
          final srvDriver = serverTrip['driver_id'];
          // Accept is "good" if the backend has us as driver OR the trip
          // has already progressed past 'requested'.
          const liveStatuses = {
            'accepted', 'driver_en_route', 'driver_arriving',
            'arrived', 'driver_arrived', 'in_trip', 'in_progress',
          };
          if (liveStatuses.contains(srvStatus) ||
              (srvDriver != null && srvDriver.toString() == _driverId.toString())) {
            serverHasTrip = true;
            debugPrint(
              '[DriverOnline] accept verified on server (status=$srvStatus driver=$srvDriver) — keeping trip alive',
            );
          }
        } catch (verifyErr) {
          debugPrint('[DriverOnline] getTrip verify failed: $verifyErr');
          verifyFailed = true;
        }
      }
      if (serverHasTrip) {
        // The client lost the accept response but the server is
        // happily running the trip. Swallow the error, stay on the
        // trip screen, let the driver continue.
        // Fall through to the normal result handling below.
      } else if (verifyFailed) {
        // getTrip itself failed (timeout/network). We cannot confirm the
        // accept failed — the original timeout was likely just the response
        // being slow. Be optimistic: assume the accept succeeded and let
        // the driver continue to the trip screen. If the accept really
        // failed, the trip screen will handle that gracefully.
        debugPrint(
          '[DriverOnline] verify failed — assuming accept succeeded optimistically',
        );
        serverHasTrip = true;
        // Fall through to normal handling.
      } else {
        // Accept genuinely failed — offer is gone. Do NOT cancel the trip
        // (the driver never owned it anyway), but DO undo the optimistic
        // Firestore write from STEP 5: it already told the rider a driver
        // was en route. Left as-is, the rider watches a driver who was
        // never dispatched while the trip is locked to this app.
        _hideAcceptedOverlay();
        if (tripId != null) {
          // notify: false — the driver already gets the clearer
          // "trip no longer available" message just below.
          await _returnTripToDispatch(
            tripId,
            reason: 'accept_failed',
            notify: false,
          );
        }
        // mounted guard required: previous awaits (getTrip, release) mean
        // context may be defunct if the driver navigated away mid-verify.
        if (mounted) {
          _setState(() {
            _offerAcceptState = _OfferAcceptState.normal;
            _acceptingCardId = null;
          });
          _snack(S.of(context).tripNoLongerAvailable);
        }
        _resetToSearchingOnRemoteCancel();
        return;
      }
    }
    // ── STEP 8: let the celebration play out, then hand the trip over ──
    // The 30s navFuture timeout that used to live here was a bandage for
    // TripAcceptedScreen crashing on its own map. There is no second route
    // to time out anymore — the overlay is ours and the handoff below is
    // a plain push we own end to end.
    await celebration;
    if (!mounted) return;

    // Hand off with the celebration still up: it covers the canvas through
    // the route fade, and _pushTripScreen drops both it and our map once
    // the trip screen is actually on top.
    handedOff = true;
    final String? result = await _pushTripScreen(
      tripId:         acceptedTripId,
      riderName:      name,
      riderPhotoUrl:  riderPhotoUrl,
      riderRating:    riderRating,
      riderIsNew:     riderIsNew,
      routePoints:    preRoutePoints,
    );
    if (!mounted) return;
    _hideAcceptedOverlay();
    if (result == 'completed') {
      // Back on this screen for the earnings overlay — bring the map back.
      _remountMapSurface();
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
      _doneCtrl?.forward(from: 0);
    } else if (result == 'back_to_home') {
      // Driver pressed back to go home — trip is still active.
      // Navigate to DriverHomeScreen with returnFromTrip so the Resume
      // button appears.  Do NOT call _cancel() — the trip must survive.
      _goBackToHomeWithTrip();
    } else if (result == 'cancelled') {
      // Trip screen reports a remote cancellation (dispatch or auto-cancel).
      // The driver cannot cancel trips directly anymore — this branch is
      // only reached when the trip was ended from outside the driver app.
      // Just reset local state and return to searching with a gold toast.
      debugPrint('[DriverOnline] trip screen popped with result=cancelled — remote cancel, resetting');
      _resetToSearchingOnRemoteCancel();
    } else {
      // result == null — DriverTripAcceptScreen left via pushAndRemoveUntil
      // (rating screen, home) rather than popping a result, so nothing was
      // handed back. It owns the trip lifecycle from `arrived` onward and
      // its own exit navigation; touching trip state from here would race
      // its transitions. Never cancel here — that was the v293 phantom
      // cancel that showed the rider "Ride Cancelled by operator" while
      // the driver was still driving.
      debugPrint(
        '[DriverOnline] trip screen returned null — it navigated away on its '
        'own. Leaving the trip alone.',
      );
      // If we somehow survived underneath, bring the canvas back.
      _remountMapSurface();
      // Clear local offer/trip refs so a later back_to_home pop doesn't
      // make the controller think a ghost trip is still in progress.
      _tripId = null;
      _currentOfferId = null;
    }
    } catch (e, stack) {
      debugPrint('[DriverOnline] ═══════════════════════════════════════');
      debugPrint('[DriverOnline] _acceptOffer unexpected error: $e');
      debugPrint('[DriverOnline] offerId=$offerId, tripId=$tripId');
      debugPrint('[DriverOnline] mounted=$mounted, phase=$_phase');
      debugPrint(stack.toString());
      debugPrint('[DriverOnline] ═══════════════════════════════════════');
      _hideAcceptedOverlay();
      _remountMapSurface();
      // We may already be the assigned driver — the backend commits the
      // accept before this app finishes setting up the trip. Blowing up
      // here without releasing leaves the trip in driver_en_route owned by
      // an app that cannot drive it: the rider watches a driver who never
      // arrives and dispatch can't reassign. Hand it back.
      // `handedOff` keeps this off trips that DriverTripAcceptScreen is
      // legitimately running.
      // ...unless the trip is already ours. A 409 "offer already accepted"
      // is the expected answer when the same trip reaches this driver
      // twice: they take the first card, the trip is theirs, and tapping
      // the leftover card lands here. Releasing then hands away a trip the
      // driver legitimately holds and is about to drive — the rider is
      // shown a driver, the driver is shown an error, and the trip goes
      // back to the queue underneath both of them. Ask who owns it before
      // giving it up.
      if (!handedOff && tripId != null) {
        unawaited(() async {
          if (await _tripIsAlreadyMine(tripId)) {
            debugPrint('[DriverOnline] accept threw but trip $tripId is '
                'already assigned to us — opening it');
            // Open it, don't just say so. The accept worked; only the
            // setup after it failed. Telling the driver "this trip is
            // already yours" and leaving them on the offers list makes
            // them find their own way to a trip they are supposed to be
            // driving — which is what "close and reopen the app puts me
            // in the ride" was really reporting.
            if (!mounted) return;
            // Coerced, not cast — the payload is the same one whose hard
            // casts used to throw and land us in this very catch.
            String text(dynamic v, String fallback) {
              if (v == null) return fallback;
              final s = v.toString().trim();
              return s.isEmpty ? fallback : s;
            }
            await _pushTripScreen(
              tripId: tripId,
              riderName: text(r['rider_name'], 'Rider'),
              riderPhotoUrl: text(r['rider_photo_url'], ''),
              riderRating: (r['rider_rating'] as num?)?.toDouble() ?? 0.0,
              riderIsNew: r['rider_is_new'] == true,
            );
            return;
          }
          await _returnTripToDispatch(tripId, reason: 'driver_app_error');
        }());
      }
      if (mounted) {
        _setState(() {
          _offerAcceptState = _OfferAcceptState.normal;
          _acceptingCardId = null;
        });
        final errStr = e.toString().toLowerCase();
        final isNetworkError = errStr.contains('socket') ||
            errStr.contains('timeout') ||
            errStr.contains('unreachable') ||
            errStr.contains('connection') ||
            errStr.contains('network');
        final msg = isNetworkError
            ? 'Network error. Please check your connection and try again.'
            : 'Error accepting offer. Please try again.';
        _snack(msg);
      }
    }
  }

  // ═══════════════════════════════════════════════════════════
  //  ACCEPTED CELEBRATION — single canvas
  // ═══════════════════════════════════════════════════════════

  /// Paint the accepted trip onto the map this screen already owns:
  /// the cinematic camera toward the pickup, the pickup/dropoff pins and
  /// the gold route. All of this used to be drawn on TripAcceptedScreen's
  /// own throwaway MapWidget.
  ///
  /// Fire-and-forget: the celebration clock must not wait on a Directions
  /// API call, and every step bails the moment the overlay is gone.
  ///
  /// Nothing in here may throw. It runs unawaited, so an escaping error
  /// becomes an uncaught zone exception — cosmetic map work would be
  /// crashing the app it was meant to stop crashing.
  Future<void> _paintAcceptedRoute(List<LatLng>? preRoutePoints) async {
    try {
      await _paintAcceptedRouteInner(preRoutePoints);
    } catch (e, s) {
      debugPrint('[DriverOnline] _paintAcceptedRoute failed: $e\n$s');
    }
  }

  Future<void> _paintAcceptedRouteInner(List<LatLng>? preRoutePoints) async {
    final driverPos = _pos ?? _pickupLL;

    // Frame driver → pickup with the same tilt the old screen opened on.
    final center = safePoint(
      (driverPos.longitude + _pickupLL.longitude) / 2,
      (driverPos.latitude + _pickupLL.latitude) / 2,
    );
    if (center != null) {
      try {
        _map?.flyTo(
          mapbox.CameraOptions(
            center: center,
            zoom: 14.5,
            pitch: 20.0,
            bearing: _bearingBetween(driverPos, _pickupLL),
          ),
          mapbox.MapAnimationOptions(duration: 900),
        );
      } catch (e) {
        debugPrint('[DriverOnline] accepted camera failed: $e');
      }
    }

    try {
      await _setPickupDropoffAnnotations();
    } catch (e) {
      debugPrint('[DriverOnline] accepted pins failed: $e');
    }
    if (!mounted || _acceptedOverlay == null) return;

    var pts = preRoutePoints;
    if (pts == null || pts.length < 2) {
      pts = await _fetchRoutePoints(driverPos, _pickupLL);
    }
    if (!mounted || _acceptedOverlay == null || pts.length < 2) return;
    try {
      // stillWanted overrides the helper's default "a preview is open"
      // liveness check — the preview was torn down before we got here.
      await _drawGoldGlossRoute(
        pts,
        stillWanted: () => _acceptedOverlay != null,
      );
    } catch (e) {
      debugPrint('[DriverOnline] accepted route draw failed: $e');
    }
  }

  /// Take the celebration off screen. Safe to call more than once.
  void _hideAcceptedOverlay() {
    if (_acceptedOverlay == null) return;
    _setState(() => _acceptedOverlay = null);
  }

  /// Hand the trip over to [DriverTripAcceptScreen].
  ///
  /// That screen mounts its own MapWidget, so ours is dropped as soon as
  /// the transition lands — only one native Mapbox surface may be alive at
  /// a time on iOS. Remounting is the caller's call: the paths that leave
  /// this screen for good shouldn't pay for a PlatformView they are about
  /// to throw away.
  Future<String?> _pushTripScreen({
    required int tripId,
    required String riderName,
    required String riderPhotoUrl,
    required double riderRating,
    required bool riderIsNew,
    List<LatLng>? routePoints,
  }) {
    final future = Navigator.of(context).push<String>(
      smoothFadeRoute(
        DriverTripAcceptScreen(
          tripId:         tripId,
          riderName:      riderName,
          riderPhotoUrl:  riderPhotoUrl,
          riderRating:    riderRating,
          riderIsNew:     riderIsNew,
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
          routePoints:    routePoints,
        ),
      ),
    );

    // Tear our surface down only once the 280ms fade has landed and the
    // trip screen actually covers us. Unmounting a PlatformView under a
    // half-transparent route flashes the "Finding trips" placeholder in
    // the driver's face; the celebration overlay is what hides the swap.
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      // isCurrent means nothing is on top of us anymore — the trip screen
      // came and went inside the fade window, so keep the map (rule 12).
      if (ModalRoute.of(context)?.isCurrent == true) return;
      _hideAcceptedOverlay();
      _releaseMapSurface();
    });

    return future;
  }

  /// Tear down our native map so the screen on top of us can own the only
  /// live Mapbox surface. Every annotation handle belongs to the
  /// PlatformView being destroyed, so they all go with it; onMapCreated
  /// rebuilds them against the fresh map on remount (same path Android
  /// already takes when it recreates the SurfaceView after a background).
  void _releaseMapSurface() {
    if (!_mapMounted) return;
    debugPrint('[DriverOnline] releasing map surface');
    _dotWatchdog?.cancel();
    _smoothTicker?.stop();
    _routeDrawTicker?.stop();
    _pinPopTicker?.stop();
    // Bump the generation so any in-flight annotation work recognises its
    // handles as dead instead of poking a destroyed native object.
    _mapGeneration++;
    _polylineAnnotMgr = null;
    _pointAnnotMgr = null;
    _pinAnnotMgr = null;
    _carAnnot = null;
    _carAnnotGen = 0;
    _goldDotAnnot = null;
    _goldDotAnnotGen = 0;
    _pickupAnnot = null;
    _dropoffAnnot = null;
    _prevDriverAnnot = null;
    _prevPickupAnnot = null;
    _prevDropoffAnnot = null;
    _routeAnnot = null;
    _previewPickupAnnot = null;
    _previewDropoffAnnot = null;
    _dotPopDone = false;
    _dotPopScale = 0.0;
    _map = null;
    _setState(() => _mapMounted = false);
  }

  /// Bring the canvas back after the screen above us is gone.
  void _remountMapSurface() {
    if (_mapMounted || !mounted) return;
    debugPrint('[DriverOnline] remounting map surface');
    _setState(() => _mapMounted = true);
    // onMapCreated redraws the driver annotation; the watchdog re-asserts
    // it if the bitmap wasn't ready on the first pass.
    _startDotWatchdog();
  }

  /// Give an assigned trip back to dispatch.
  ///
  /// This app told the backend (and, optimistically, Firestore) that it was
  /// taking the trip, and then couldn't. Left alone the trip sits in
  /// `driver_en_route` with a driver who is never coming: the rider watches
  /// a phantom car and dispatch can't reassign because the trip already has
  /// an owner. The backend puts it back to `requested` and re-offers it to
  /// the next nearest driver.
  ///
  /// The optimistic Firestore write from the accept is only undone once the
  /// backend confirms the trip has no driver — either because it released
  /// it, or because it was never ours and nobody else took it. A trip past
  /// pickup, or one another driver now owns, is left alone: wiping the
  /// rider's driver info there would be the lie.
  /// Is this trip already assigned to this driver and still live?
  ///
  /// Answers the only question that matters before handing a trip back:
  /// did the accept actually fail, or did it succeed and something after
  /// it throw. Defaults to false — if we cannot tell, the safer outcome is
  /// releasing a trip we might hold (dispatch re-offers it) rather than
  /// keeping one we do not (the rider waits for nobody).
  Future<bool> _tripIsAlreadyMine(int tripId) async {
    try {
      final trip = await ApiService.getTrip(tripId);
      final assigned = (trip['driver_id'] as num?)?.toInt();
      final status = (trip['status'] ?? '').toString().toLowerCase().trim();
      const live = {
        'accepted', 'driver_en_route', 'driver_arriving', 'arrived',
        'in_trip', 'in_progress',
      };
      return assigned != null && assigned == _driverId && live.contains(status);
    } catch (e) {
      debugPrint('[DriverOnline] ownership check failed for $tripId: $e');
      return false;
    }
  }

  Future<void> _returnTripToDispatch(
    int tripId, {
    required String reason,
    bool notify = true,
  }) async {
    final driverId = _driverId;
    if (driverId == null) return;
    debugPrint('[DriverOnline] returning trip $tripId to dispatch ($reason)');
    final released = await ApiService.releaseTrip(
      tripId: tripId,
      driverId: driverId,
      reason: reason,
    );
    if (!released) {
      debugPrint('[DriverOnline] backend refused to release trip $tripId — '
          'leaving the rider view alone');
      return;
    }
    try {
      await FirebaseFirestore.instance
          .collection('trips')
          .doc('sql_$tripId')
          .set({
        // Nulls, matching the backend's own release sync — the rider's
        // listener must see "no driver", not an empty-string driver.
        'status': 'requested',
        'driver_id': null,
        'driverId': null,
        'driver_name': null,
        'driverName': null,
        'driver_phone': null,
        'driverPhone': null,
        'driver_photo_url': null,
        'driverPhotoUrl': null,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[DriverOnline] Firestore revert for trip $tripId failed: $e');
    }
    if (notify && mounted) _snack(S.of(context).tripReturnedToDispatch);
  }

  Future<void> _rejectOffer(Map<String, dynamic> r) async {
    int? toInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is double) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    try {
      HapticService.lightImpact();
      final offerId = toInt(r['offer_id']);
      if (offerId != null) _rejectedOfferIds.add(offerId);

      // INSTANT dismiss — remove card + clear map in the same frame
      if (mounted) {
        _setState(() {
          _rejectingOfferId = null;
          _pendingOffers.removeWhere((o) => o['offer_id'] == offerId);
          if (_pendingOffers.isEmpty) {
            _hideFindingBar = false;
            // FIX: Reset PageController to index 0 when no offers remain.
            // Without this, PageView keeps a stale index and crashes on
            // rebuild when new offers arrive.
            if (_offerPageCtrl.hasClients) {
              _offerPageCtrl.jumpTo(0);
            }
          }
          _previewingOffer = null;
          _offerRouteShown = false;
          _fullSegOne = [];
          _fullSegTwo = [];
        });
      }
      // Guard: don't reset a disposed controller (can throw)
      if (_rejectSlideCtrl != null &&
          (_rejectSlideCtrl!.isAnimating || _rejectSlideCtrl!.isCompleted)) {
        try { _rejectSlideCtrl!.reset(); } catch (_) {}
      }

      // CRASH FIX: Defer annotation clearing to next frame so the widget
      // tree has settled after setState. If the map was destroyed during
      // the rebuild, _clearAllAnnotations would crash trying to access
      // stale annotation managers.
      await Future.delayed(Duration.zero);
      if (!mounted) return;

      try {
        await _clearAllAnnotations();
      } catch (e) {
        debugPrint('[DriverOnline] _clearAllAnnotations failed on reject: $e');
      }

      if (_pos != null && mounted) {
        try {
          _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
        } catch (e) {
          debugPrint('[DriverOnline] _animateToPosition failed on reject: $e');
        }
      }

      // Fire-and-forget API rejection — UI already updated
      if (offerId != null && _driverId != null) {
        ApiService.rejectRideOffer(
          offerId: offerId,
          driverId: _driverId!,
        ).catchError((_) => <String, dynamic>{});
      }
      if (offerId != null) _routeCache.remove(offerId.toString());
    } catch (e, stack) {
      debugPrint('[DriverOnline] _rejectOffer error: $e');
      debugPrint(stack.toString());
    }
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
    HapticService.mediumImpact();
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
    HapticService.heavyImpact();

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
    HapticService.heavyImpact();

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
    int? toInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is double) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    // Reject all pending offers if any
    for (final offer in _pendingOffers) {
      final oid = toInt(offer['offer_id']);
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
    _stopActiveTripCancelWatcher();
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
    HapticService.heavyImpact();
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
    _doneCtrl?.forward(from: 0);
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
    _doneCtrl?.reverse();
    _stopActiveTripCancelWatcher();
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
      HapticService.heavyImpact();
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1F),
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
    HapticService.mediumImpact();
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
    HapticService.mediumImpact();
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
    HapticService.lightImpact();
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

  /// Driver pressed back from the active trip screen.
  /// Navigate to home while keeping the trip alive so the Resume button works.
  void _goBackToHomeWithTrip() {
    _pollT?.cancel();
    _offerSseSub?.cancel();
    _clock?.cancel();
    _earningsRefreshTimer?.cancel();

    // Stop navigation but do NOT cancel the trip.
    _navService.stopNavigation();
    _navState = null;
    _currentNavRoute = null;
    _navTimer?.cancel();

    final nav = Navigator.of(context);
    if (nav.canPop()) {
      // Pop back to DriverHomeScreen with stillOnline = true so it shows
      // the Resume button and keeps polling for active trip updates.
      nav.pop<Map<String, dynamic>>(<String, dynamic>{
        'earnings': _earnings,
        'trips': _trips,
        'hours': _online.inMinutes / 60.0,
        'stillOnline': true,
      });
    } else {
      nav.pushAndRemoveUntil(
        smoothFadeRoute(const DriverHomeScreen(returnFromTrip: true)),
        (_) => false,
      );
    }
  }

  /// Driver can no longer directly cancel a trip (policy 2026-04-11).
  /// When a trip is dispatch-cancelled or auto-cancelled, the rider
  /// tracking listener will fire `_handleRemoteTripCancelled()` below
  /// which resets this controller back to searching and surfaces a
  /// friendly gold SnackBar. The driver cannot initiate a cancel — the
  /// only escape path during an active trip is "Contact Support", which
  /// creates an action request for dispatch.
  ///
  /// This method now ONLY resets the local controller state and returns
  /// the screen to the searching phase. It never PATCHes the backend.
  void _resetToSearchingOnRemoteCancel() {
    // All callers are async-after-await, so the State may already be
    // disposed by the time we land here.
    if (!mounted) return;
    _stopActiveTripCancelWatcher();
    _hideAcceptedOverlay();
    // We may be coming back from DriverTripAcceptScreen, which owned the
    // only live map surface while it was up.
    _remountMapSurface();
    _navService.stopNavigation();
    _navState = null;
    _currentNavRoute = null;
    _navTimer?.cancel();
    // FIX: Clear _acceptedOfferIds so the driver can accept future offers
    // with the same ID. Previously this was never cleared, causing the
    // idempotent guard in _acceptOffer to permanently block re-acceptance.
    _acceptedOfferIds.clear();
    _setState(() {
      _phase = _Phase.searching;
      _tripId = null;
      _currentOfferId = null;
      _routePts = [];
      _pendingOffers = [];
      _offerAcceptState = _OfferAcceptState.normal;
      _acceptingCardId = null;
    });
    if (!mounted) return;
    _syncSearchPulse();
    _clearAllAnnotations();
    if (_pos != null) _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
    _startPolling();
    if (mounted) {
      // Use maybeOf — if the screen has no Scaffold ancestor (e.g. mid
      // teardown) we silently skip the toast instead of crashing.
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF1a1a1a),
          content: Row(
            children: [
              const Icon(Icons.info_outline,
                  color: Color(0xFFE8C547), size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  S.of(context).driverTripCancelledReturning,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          duration: const Duration(seconds: 4),
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFFE8C547), width: 1),
          ),
        ),
      );
    }
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  NAV — Real GPS drives the navigation now.
  //  _simNav is kept as a no-op for backward compat.
  //  (_startActiveTripCancelWatcher / _handleExternalTripCancel defined below)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _simNav() {
    // No-op: real GPS position stream handles all nav updates
  }

  /// Start a Firestore snapshot listener on the active trip doc. Fires
  /// [_handleExternalTripCancel] as soon as the backend flips the trip to
  /// cancelled, regardless of which screen is currently on top of the
  /// navigator stack. This is the definitive detection mechanism for
  /// dispatch-initiated cancels: DriverTripAcceptScreen usually leaves via
  /// pushAndRemoveUntil rather than popping a result, so the route future
  /// _acceptOffer awaits comes back null and tells the controller nothing.
  void _startActiveTripCancelWatcher(int tripId) {
    _activeTripCancelWatcher?.cancel();
    _watchedCancelTripId = tripId;
    final docId = 'sql_$tripId';
    _activeTripCancelWatcher = FirebaseFirestore.instance
        .collection('trips')
        .doc(docId)
        .snapshots()
        .listen(
      (snap) {
        if (!mounted) return;
        if (_watchedCancelTripId != tripId) return; // stale listener
        final data = snap.data();
        if (data == null) return;
        final status = (data['status'] ?? '').toString().toLowerCase();
        if (status == 'cancelled' || status == 'canceled') {
          debugPrint(
              '[DriverOnline] external cancel detected for trip $tripId (status=$status) — resetting');
          _handleExternalTripCancel();
        }
      },
      onError: (e) {
        debugPrint('[DriverOnline] cancel watcher error for $tripId: $e');
        final isPermDenied = e is FirebaseException && e.code == 'permission-denied';
        if (isPermDenied || e.toString().contains('permission-denied')) {
          FirebaseAuth.instance.signInAnonymously().ignore();
        }
      },
    );
    debugPrint('[DriverOnline] cancel watcher armed on $docId');
  }

  /// Tear down the cancel watcher. Safe to call multiple times.
  void _stopActiveTripCancelWatcher() {
    _activeTripCancelWatcher?.cancel();
    _activeTripCancelWatcher = null;
    _watchedCancelTripId = null;
  }

  /// Shared handler for a remote cancel fired from the Firestore watcher.
  /// Pops every route pushed on top of DriverOnlineScreen
  /// (DriverTripAcceptScreen, DriverNavScreen, ...) and then resets the
  /// controller back to the searching phase — which also remounts our map,
  /// since the screen above us owned the only live surface.
  void _handleExternalTripCancel() {
    if (!mounted) return;
    _stopActiveTripCancelWatcher();
    // ModalRoute.of(context) gives the route of DriverOnlineScreen itself,
    // so popUntil stops there. If we are already the top route, popUntil
    // is a no-op and _resetToSearchingOnRemoteCancel does the rest.
    final myRoute = ModalRoute.of(context);
    if (myRoute != null) {
      try {
        Navigator.of(context).popUntil((r) => r == myRoute || r.isFirst);
      } catch (e) {
        debugPrint('[DriverOnline] popUntil on cancel failed: $e');
      }
    }
    _resetToSearchingOnRemoteCancel();
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
                  .replaceAll(_htmlTagRe, '');
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
              final distVal = leg['distance']['value'];
              final durVal = leg['duration']['value'];
              _navDist = (distVal is num ? distVal.toDouble() : 0.0) / 1609.34;
              _navEta = ((durVal is num ? durVal.toDouble() : 0.0) / 60).ceil();
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
