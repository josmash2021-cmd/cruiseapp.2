part of 'driver_online_screen.dart';

// ══════════════════════════════════════════════════════════════
//  CONTROLLER — boot, GPS, polling, offers, navigation, trips
// ══════════════════════════════════════════════════════════════

extension _DriverOnlineController on _DriverOnlineScreenState {

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  BOOT
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Future<void> _boot() async {
    // Retry getting driver ID up to 3 times (critical for dispatch)
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        final id = await ApiService.getCurrentUserId();
        if (id != null) {
          _driverId = id;
          debugPrint('âœ… Got driverId=$_driverId on attempt $attempt');
          break;
        }
      } catch (e) {
        debugPrint('âš ï¸ getCurrentUserId attempt $attempt failed: $e');
      }
      if (attempt < 3) await Future.delayed(const Duration(seconds: 1));
    }
    if (_driverId == null) {
      debugPrint('âŒ Could not get driver ID after 3 attempts');
    }
    // Run GPS + icon loading in parallel — they are independent
    await Future.wait([_locate(), _buildVehicleIcons()]);
    // Gate: check verification / background check status before going online
    await _verifyDriverApproval();
    _goOnlineBackend();

    // Pre-cache map tiles around driver's current area (silent background)
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

    _startClock();
    _startPolling();
    _startPosStream();
    _loadWeeklyEarnings();
  }

  Future<void> _loadWeeklyEarnings() async {
    try {
      final data = await ApiService.getDriverEarnings(period: 'week');
      if (mounted) {
        _setState(() {
          _weeklyEarnings = (data['total'] as num?)?.toDouble() ?? 0;
        });
      }
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
    _suvIconBytes = await CarIconLoader.loadForRideBytes('Suburban');
    _sedanIconBytes = await CarIconLoader.loadForRideBytes('Camry');
    _arrowIconBytes = _suvIconBytes;
    // Skip PNG navatar sprites (contain blue circle overlay); use single rotated canvas car
    _navCarSprites = null;
    _navCarIconBytes = await CarIconLoader.loadUberBytes();
    await _loadDriverPhoto();
    await _goldDot.build(() { if (mounted) _updateDriverAnnotation(); });
    _goldPinBytes = await renderCircularPinBytes(icon: CircularPinIcon.person, isPickup: true, radius: 32);
    if (mounted) _setState(() {});
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
      // Allow: clear/approved OR not-yet-configured ('none')
      if (bgStatus == 'clear' || bgStatus == 'none' ||
          verStatus == 'approved' || verStatus == 'none') {
        _approvalGatePassed = true;
        return;
      }
      _approvalGatePassed = false;
      if (!mounted) return;
      String title;
      String message;
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
    if (_pos == null) return;
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
        })
        .catchError((e) {
          debugPrint('âŒ Failed to go online: $e');
        });
  }

  void _goOfflineBackend() {
    if (_driverId == null || _pos == null) return;
    AnalyticsService.instance.logDriverOffline();
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
            distanceFilter: 1, // 1 meter for maximum smooth movement
          ),
        ).listen((pos) {
          if (!mounted) return;
          final newLL = LatLng(pos.latitude, pos.longitude);
          _smoothedBearing = _lerpAngle(_smoothedBearing, pos.heading, 0.30);
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

          // Always update driver location to backend
          if (_driverId != null) {
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
    _animFrom = _pos!;
    _animTo = target;
    _targetHeading = heading;
    _driverAnim.forward(from: 0);
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

  void _onDriverAnimTick() {
    if (!mounted) return;
    final t = Curves.easeInOutCubic.transform(_driverAnim.value);
    final lat =
        _animFrom.latitude + (_animTo.latitude - _animFrom.latitude) * t;
    final lng =
        _animFrom.longitude + (_animTo.longitude - _animFrom.longitude) * t;
    _pos = LatLng(lat, lng);

    // Super smooth bearing interpolation
    double diff = _targetHeading - _heading;
    while (diff > 180) { diff -= 360; }
    while (diff < -180) { diff += 360; }
    _heading += diff * (t * 0.25).clamp(0.0, 1.0);

    // Unified camera following (single source of truth for all phases)
    final isNav = _phase == _Phase.enRouteToPickup || _phase == _Phase.inTrip;
    if (_phase == _Phase.searching) {
      // Searching: instant camera update — setCamera avoids animation conflicts at 60fps
      _map?.setCamera(
        mapbox.CameraOptions(
          center: mapbox.Point(
              coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),
          zoom: 15.5,
          bearing: 0,
          pitch: 0,
        ),
      );
    } else if (isNav && _cameraFollowing) {
      // Navigation: 2.5D chase cam using lerped position + bearing
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
    _sseActive = false;

    // SSE real-time stream (instant offer push from backend)
    if (_driverId != null) {
      _offerSseSub = ApiService.streamDriverOffers(_driverId!).listen(
        (offers) {
          _sseActive = true;
          debugPrint('SSE offers: ${offers.length}');
          if (!mounted || _phase != _Phase.searching) return;
          _applyOffers(offers);
        },
        onError: (e) {
          debugPrint('SSE offers error: $e');
          _sseActive = false;
        },
        onDone: () {
          debugPrint('SSE offers stream ended, polling continues');
          _sseActive = false;
        },
      );
    }

    // Polling fallback (slower when SSE is active, never fully skipped)
    _poll();
    int pollTick = 0;
    _pollT = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || _phase != _Phase.searching) return;
      pollTick++;
      // When SSE is delivering, poll every 3rd tick (15s) as safety net
      if (_sseActive && pollTick % 3 != 0) return;
      _poll();
    });
  }

  /// Apply incoming offers to UI (shared by SSE + polling).
  void _applyOffers(List<Map<String, dynamic>> offers) {
    if (offers.isNotEmpty && _pendingOffers.isEmpty) {
      HapticFeedback.heavyImpact();
    }
    final hadOffers = _pendingOffers.isNotEmpty;
    _setState(() {
      _pendingOffers = offers;
      _currentOfferIndex = _currentOfferIndex.clamp(0, offers.length - 1);
      if (offers.isNotEmpty && !hadOffers) _hideFindingBar = true;
      if (offers.isEmpty && hadOffers) _hideFindingBar = false;
    });
    _preFetchOfferRoutes(offers);
    if (offers.isNotEmpty && !hadOffers) {
      _autoTriggerRoutePreview(offers.first);
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
    _riderPhotoUrl = (r['rider_photo_url'] ?? r['photo_url'] ?? '') as String;
    _riderPhone = (r['rider_phone'] ?? '') as String;
    _pickupAddr = r['pickup_address'] ?? 'Pickup';
    _dropoffAddr = r['dropoff_address'] ?? 'Drop-off';
    _fare = (r['fare'] as num?)?.toDouble() ?? 0;
    _vehicleType = _mapRideType((r['vehicle_type'] ?? 'Comfort') as String);
    _distToPickup = _hav(_pos!, _pickupLL);
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
    _setState(() {
      _offerAcceptState = _OfferAcceptState.normal;
      _acceptingCardId = null;
    });

    if (!mounted) return;
    final riderPhotoUrl = (r['rider_photo_url'] ?? r['photo_url'] ?? '') as String;
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
          pickupLatLng:   _pickupLL,
          dropoffLatLng:  _dropoffLL,
          pickupAddress:  _pickupAddr,
          dropoffAddress: _dropoffAddr,
          fare:           _fare,
          vehicleType:    _vehicleType,
          driverPos:      _pos!,
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
        _earnings += _fare;
        _lastTripEarnings = _fare;
        _phase = _Phase.completed;
        _stars = 5;
      });
      _doneCtrl.forward(from: 0);
    } else {
      // Cancelled or back-pressed — return to searching
      _cancel();
    }
  }

  Future<void> _rejectOffer(Map<String, dynamic> r) async {
    HapticFeedback.lightImpact();
    final offerId = r['offer_id'] as int?;

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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('El rider no ha confirmado, comenzando viaje...'),
        duration: Duration(seconds: 2),
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
    }
    if (!mounted) return;
    _setState(() {
      _trips++;
      _earnings += _fare;
      _lastTripEarnings = _fare;
      _phase = _Phase.completed;
      _stars = 5;
    });
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
    _clearAllAnnotations();
    if (_pos != null) _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
    _startPolling();
  }

  void _goOffline() {
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
    Navigator.of(context).pop<Map<String, dynamic>>({
      'earnings': _earnings,
      'trips': _trips,
      'hours': _online.inMinutes / 60.0,
      'stillOnline': false,
    });
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
              child: const Text('Resume Now'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _scheduleResume(minutes: 15);
                _snack('⏸️ Paused for 15 minutes');
              },
              child: const Text('15 min'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _scheduleResume(minutes: 30);
                _snack('⏸️ Paused for 30 minutes');
              },
              child: const Text('30 min'),
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
    Navigator.of(context).pop<Map<String, dynamic>>({
      'earnings': _earnings,
      'trips': _trips,
      'hours': _online.inMinutes / 60.0,
      'stillOnline': true,
    });
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
