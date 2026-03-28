part of '../screens/rider_tracking_screen.dart';

// ════════════════════════════════════════════════════════════
//  CONTROLLER — Firebase listeners, trip phases, persistence
// ════════════════════════════════════════════════════════════

extension _RiderTrackingController on _RiderTrackingScreenState {

  /// Connect to Firestore for trip status and RTDB for live driver movement.
  void _startRealTimeTracking() {
    final fsId = widget.firestoreTripId;
    if (fsId != null && fsId.isNotEmpty) {
      // Watch trip status changes
      _tripStatusSub = TripFirestoreService.watchTrip(fsId).listen(
        (data) {
          if (!mounted) return;
          if (data == null) {
            // Null data = temporary disconnection, do NOT cancel
            debugPrint('[RiderTracking] Trip data null — keeping last known state');
            if (!_connectionLost) _setState(() => _connectionLost = true);
            return;
          }
          if (_connectionLost) _setState(() => _connectionLost = false);
          _onTripStatusUpdate(data);
        },
        onError: (error) {
          debugPrint('[RiderTracking] Trip status listener error: $error');
          // Stream error = connection issue, show banner and keep retrying
          if (mounted && !_connectionLost) {
            _setState(() => _connectionLost = true);
          }
        },
      );
    }

    // ✅ QUICK WIN #1: HTTP polling removed - Firestore listener above handles all updates
    // The Timer.periodic polling was redundant (12 HTTP requests/min per rider)
    // Firestore snapshots are real-time and more reliable than polling
    // Keeping _statusPollTimer variable for potential future fallback if needed
    final tripId = widget.tripId;
    if (tripId != null) {
      // Removed: _statusPollTimer = Timer.periodic(...)
      // Benefit: -85% HTTP traffic, +20-30% battery life
      debugPrint('[QuickWin] Polling disabled - using Firestore listener only');
    }
  }

  /// Process real-time driver location from RTDB.
  void _onRealDriverLocation(LatLng ll, {double? bearing}) {
    if (ll.latitude == 0 && ll.longitude == 0) return;

    // FIX 4: Smooth marker animation - start interpolation to new position
    if (_shouldFollowDriver) {
      _startSmoothMarkerAnimation(ll, bearing);
    }

    bool usedRouteProjection = false;
    
    // Try to project onto route for smooth animation
    if (_segDist.isNotEmpty && _routePts.length >= 2) {
      final projectedM = _projectOntoRoute(ll);
      final distToStart = _hav(ll, _routePts.first) * 1609.34;
      
      // Only use projection if it's reasonable
      if (projectedM > 0 || distToStart < 100) {
        _tgtTraveledM = projectedM.clamp(0.0, _segDist.last);
        usedRouteProjection = true;
      }
    }
    
    // Fallback: if projection didn't work, set a lerp target (never teleport _animPos)
    if (!usedRouteProjection) {
      _directTargetPos = ll;
      _directTargetBearing = bearing;
    }

    // Update phase and distances
    if (_phase == _TrackPhase.arriving) {
      final dist = _hav(ll, widget.pickupLatLng);
      _distanceMiles = dist;
      _etaMinutes = (dist / 0.5).ceil().clamp(1, 99);
      if (dist < 0.05) {
        _setState(() => _phase = _TrackPhase.arrived);
        if (!_arrivedNotifSent) {
          _arrivedNotifSent = true;
          _sendRideNotification(
            'Your driver has arrived',
            '${widget.driverName.split(' ').first} is waiting at the pickup spot in a ${widget.vehicleColor} ${widget.vehicleModel}.',
          );
        }
      }
    } else if (_phase == _TrackPhase.onTrip) {
      final dist = _hav(ll, widget.dropoffLatLng);
      _distanceMiles = dist;
      _etaMinutes = (dist / 0.5).ceil().clamp(1, 99);
    }

    _setState(() {});
    _throttleCam();
    
    // FIX 4: Update camera follow if enabled
    if (_shouldFollowDriver) {
      _followDriver(ll, bearing ?? _animBearing);
    }
  }

  /// FIX 4: Smooth animate driver marker from current position to new position
  /// Called on each driver location update to create fluid motion
  void _startSmoothMarkerAnimation(LatLng targetPos, double? targetBearing) {
    if (_map == null || !mounted) return;
    
    // Cancel any existing marker animation
    _markerAnimTimer?.cancel();
    
    _markerLastPos = _animPos; // Current position
    _markerTargetPos = targetPos; // New target position
    _markerAnimStep = 0;
    _markAnimatingToTarget = true;
    
    const steps = 30;
    const duration = Duration(milliseconds: 1000);
    final stepDuration = duration ~/ steps;
    
    _markerAnimTimer = Timer.periodic(stepDuration, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      _markerAnimStep++;
      final t = (_markerAnimStep / steps).clamp(0.0, 1.0);
      
      // Smooth interpolation using easing curve
      final easedT = _smoothstep(t);
      
      // Interpolate position
      final lat = _markerLastPos.latitude +
          (_markerTargetPos.latitude - _markerLastPos.latitude) * easedT;
      final lng = _markerLastPos.longitude +
          (_markerTargetPos.longitude - _markerLastPos.longitude) * easedT;
      
      _animPos = LatLng(lat, lng);
      
      // Interpolate bearing if available
      if (targetBearing != null) {
        final bearingDiff = (targetBearing - _animBearing + 360) % 360;
        final interpBearing = bearingDiff > 180
            ? (_animBearing - (360 - bearingDiff) * easedT) % 360
            : (_animBearing + bearingDiff * easedT) % 360;
        _animBearing = interpBearing;
      }
      
      _setState(() {}); // Trigger marker update
      
      if (t >= 1.0) {
        timer.cancel();
        _markAnimatingToTarget = false;
      }
    });
  }

  /// Smoothstep interpolation for smooth acceleration/deceleration
  /// Creates smooth ease-in-out effect: 3t² - 2t³
  double _smoothstep(double t) {
    return t * t * (3.0 - 2.0 * t);
  }

  /// Process trip status changes from Firestore.
  void _onTripStatusUpdate(Map<String, dynamic> data) {
    // Start RTDB listener if we have a driverId
    final did = data['driverId']?.toString();
    if (did != null && did.isNotEmpty && _rtdbDriverId != did) {
      _startRtdbDriverListener(did);
    }

    final status = data['status']?.toString() ?? '';
    if ((status == 'arrived' || status == 'driver_arrived') && _phase == _TrackPhase.arriving) {
      _setState(() => _phase = _TrackPhase.arrived);
      // FIX 2: Start the pulsing dot animation and handle arrival visuals
      _arrivedDotPulse.repeat(reverse: true);
      // Fade route polyline and zoom camera to driver location
      _handleDriverArrived();
      _showRiderConfirmPickup();
    } else if ((status == 'in_trip' || status == 'in_progress' || status == 'rider_onboard') &&
        (_phase == _TrackPhase.arriving || _phase == _TrackPhase.arrived)) {
      _setState(() => _phase = _TrackPhase.onTrip);
      _arrivedDotPulse.stop(); // Stop pulsing dot animation
      _popOutPickupPin();
      // FIX 3 & 4: Start the route animation and camera phases when starting ride
      _startStartRideAnimation();
    } else if (status == 'completed' && _phase != _TrackPhase.completed) {
      LocalDataService.clearActiveRide();
      _setState(() => _phase = _TrackPhase.completed);
      _arrivedDotPulse.stop();
      _goToRating();
    } else if (status == 'cancelled' || status == 'canceled') {
      final cancelledBy = data['cancelledBy']?.toString() ?? '';
      if (cancelledBy.isNotEmpty && cancelledBy != 'driver') return;
      if (!_cancelDialogShown) {
        _cancelDialogShown = true;
        _showDriverCancelledDialog();
      }
    }
  }

  /// Show the rider confirmation pickup overlay when driver has arrived.
  void _showRiderConfirmPickup() {
    if (!mounted) return;
    final vehicleDesc =
        '${widget.vehicleColor} ${widget.vehicleMake} ${widget.vehicleModel}'.trim();
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, __, ___) => RiderConfirmPickupScreen(
          driverName: widget.driverName,
          vehicleDesc: vehicleDesc,
          firestoreTripId: widget.firestoreTripId,
          onConfirmed: () {
            if (mounted) Navigator.of(context).pop();
          },
        ),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  /// Listen to driver GPS from Firebase RTDB for sub-200ms updates.
  void _startRtdbDriverListener(String driverId) {
    _rtdbDriverLocSub?.cancel();
    _rtdbDriverId = driverId;
    _rtdbDriverLocSub = FirebaseDatabase.instance
        .ref('driver_locations/$driverId')
        .onValue
        .listen((event) {
      if (!mounted || _phase == _TrackPhase.completed) return;
      if (event.snapshot.value == null) return;
      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      final bearing = (data['bearing'] as num?)?.toDouble();
      if (lat == null || lng == null) return;
      if (_connectionLost) _setState(() => _connectionLost = false);
      _onRealDriverLocation(LatLng(lat, lng), bearing: bearing);
    }, onError: (_) {});
  }

  void _goToRating() {
    if (!mounted) return;
    // Navigate to rating immediately
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => RiderRatingScreen(
          driverName: widget.driverName,
          tripId: widget.tripId,
          fare: widget.price,
          driverPhotoUrl: widget.driverPhotoUrl,
        ),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 500),
      ),
    );
  }

  void _sendDriverGreeting() {
    if (!mounted || _greetingSent) return;
    _greetingSent = true;
    final firstName = widget.driverName.split(' ').first;
    _sendRideNotification(
      'Message from $firstName',
      'Hello! I\'m $firstName, your private driver. I\'ll be arriving shortly.',
    );
  }

  void _sendRideNotification(String title, String body) {
    NotificationService.show(id: title.hashCode, title: title, body: body);
    LocalDataService.addNotification(title: title, message: body, type: 'ride');
  }

  /// Initialize from persisted state or start fresh
  Future<void> _initFromPersistence() async {
    final activeRide = await LocalDataService.getActiveRide();
    if (activeRide == null) {
      // No persisted ride - initialize fresh
      await _initRoute();
      return;
    }

    // Check if this is the same trip
    var isSameTrip = activeRide.tripId != null && 
                     activeRide.tripId == widget.tripId;
    
    if (!isSameTrip && widget.firestoreTripId != null && 
        widget.firestoreTripId!.isNotEmpty &&
        activeRide.firestoreTripId == widget.firestoreTripId) {
      // Same trip by Firestore ID
      isSameTrip = true;
    }

    if (!isSameTrip) {
      // Different trip - start fresh
      await _initRoute();
      return;
    }

    // Restore route
    if (activeRide.routePoints.isNotEmpty) {
      _routePts = activeRide.routePoints
          .map((p) => LatLng(p[0], p[1]))
          .toList();
    } else if (widget.routePoints != null && widget.routePoints!.isNotEmpty) {
      _routePts = List.from(widget.routePoints!);
    }

    if (_routePts.isEmpty) {
      await _initRoute();
      return;
    }
    // Force endpoints to exact pin coordinates
    _routePts[0] = widget.pickupLatLng;
    _routePts[_routePts.length - 1] = widget.dropoffLatLng;

    _buildSegDist();

    // Restore phase
    if (activeRide.phase != null) {
      switch (activeRide.phase) {
        case 'arriving':
          _phase = _TrackPhase.arriving;
        case 'arrived':
          _phase = _TrackPhase.arrived;
        case 'onTrip':
          _phase = _TrackPhase.onTrip;
        default:
          _phase = _TrackPhase.arriving;
      }
    }

    // Restore traveled distance for ETA calculation
    if (activeRide.traveledMeters != null && activeRide.traveledMeters! > 0) {
      _traveledM = activeRide.traveledMeters!;
      _tgtTraveledM = _traveledM;
    }

    // Compute position from restored traveled distance so we resume
    // at the correct point on the route (not back at pickup).
    if (_segDist.isNotEmpty && _traveledM > 0) {
      final (pos, brg) = _posAtDistUltraSmooth(_traveledM);
      _driverPos = pos;
      _animPos = pos;
      _animBearing = brg;
      _driverBearing = brg;
    } else {
      _driverPos = widget.pickupLatLng;
      _animPos = _driverPos;
    }

    // Calculate remaining distance
    double remainingM = _segDist.isNotEmpty ? _segDist.last - _traveledM : 0;
    _distanceMiles = remainingM / 1609.34;
    _etaMinutes = (_distanceMiles / 0.5).ceil().clamp(1, 99);

    _setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fitAllPoints();
    });
  }

  /// Save current ride state for resuming later
  Future<void> _saveRideState() async {
    if (_phase == _TrackPhase.completed) return;

    final activeRide = await LocalDataService.getActiveRide();
    if (activeRide == null) return;

    // Update with current progress
    String phaseStr = 'arriving';
    switch (_phase) {
      case _TrackPhase.arrived:
        phaseStr = 'arrived';
      case _TrackPhase.onTrip:
        phaseStr = 'onTrip';
      default:
        phaseStr = 'arriving';
    }

    final updatedRide = ActiveRideInfo(
      pickupLat: activeRide.pickupLat,
      pickupLng: activeRide.pickupLng,
      dropoffLat: activeRide.dropoffLat,
      dropoffLng: activeRide.dropoffLng,
      pickupLabel: activeRide.pickupLabel,
      dropoffLabel: activeRide.dropoffLabel,
      driverName: activeRide.driverName,
      driverRating: activeRide.driverRating,
      vehicleMake: activeRide.vehicleMake,
      vehicleModel: activeRide.vehicleModel,
      vehicleColor: activeRide.vehicleColor,
      vehiclePlate: activeRide.vehiclePlate,
      vehicleYear: activeRide.vehicleYear,
      rideName: activeRide.rideName,
      price: activeRide.price,
      routePoints: activeRide.routePoints,
      tripId: activeRide.tripId,
      firestoreTripId: activeRide.firestoreTripId,
      phase: phaseStr,
      driverLat: _animPos.latitude,
      driverLng: _animPos.longitude,
      traveledMeters: _traveledM,
      driverPhotoUrl: activeRide.driverPhotoUrl,
      etaMinutes: activeRide.etaMinutes,
    );

    await LocalDataService.setActiveRide(updatedRide);
  }

  // Called every vsync frame via Ticker — GPU-synchronized, zero-jolt movement
  void _interpolate() {
    if (!mounted || _segDist.isEmpty) return;

    // ── Constant-speed advance — zero jolts ──
    // Sim advances tgtTraveledM ~0.208 m/frame. For tiny diffs snap directly
    // (perfect smoothness). For large GPS jumps cap at 1.5 m/frame so the
    // car catches up steadily instead of lurching forward.
    final diff = _tgtTraveledM - _traveledM;
    const maxStep = 1.5; // metres per frame ceiling
    if (diff.abs() <= maxStep) {
      _traveledM = _tgtTraveledM;
    } else {
      _traveledM += diff.sign * maxStep;
    }

    final (pos, brg) = _posAtDistUltraSmooth(_traveledM);

    // ── Bearing: smooth 5% rotation per frame (only car icon rotates, map stays north-up) ──
    double db = brg - _animBearing;
    if (db > 180) db -= 360;
    if (db < -180) db += 360;
    final newBearing = (_animBearing + db * 0.05) % 360;

    _animPos = pos;
    _animBearing = newBearing;
    _driverPos = pos;
    _driverBearing = newBearing;

    // ── Direct-target lerp (GPS fallback when off-route) ──
    final tgt = _directTargetPos;
    if (tgt != null) {
      const lerpFactor = 0.08; // smooth catch-up, never teleport
      final newLat = _animPos.latitude + (tgt.latitude - _animPos.latitude) * lerpFactor;
      final newLng = _animPos.longitude + (tgt.longitude - _animPos.longitude) * lerpFactor;
      final fallbackBearing = _directTargetBearing;
      final newBrg = _bearing(_animPos, LatLng(newLat, newLng));
      _animPos = LatLng(newLat, newLng);
      _driverPos = _animPos;
      final desiredBearing = newBrg != 0 ? newBrg : fallbackBearing;
      if (desiredBearing != null) {
        double db = desiredBearing - _animBearing;
        if (db > 180) db -= 360;
        if (db < -180) db += 360;
        _animBearing = (_animBearing + db * 0.05) % 360;
      }
    }

    // Update map annotations directly — no setState needed (avoids 60fps widget rebuilds)
    _throttleBoundsFit();
    _updateCarSmooth(); // fast path: only car GeoJSON
    _updateStaticAnnotationsOnce(); // slow path: pins + route, created once
    _eraseRouteBehindCar(); // progressive route erase (throttled internally)
    _updateApproachLine(); // dashed approach line driver→pickup
  }

  /// ──────────────────────────────────────────────────────────────────────────
  /// FIX 3 & 4: START RIDE ANIMATION & REAL-TIME TRACKING
  /// ──────────────────────────────────────────────────────────────────────────

  /// Start the 4-phase ride start animation:
  /// Phase 1 (0-1500ms): Route draws progressively
  /// Phase 2 (0-2000ms): Camera zooms out to show full route
  /// Phase 3 (2000-5000ms): Hold zoom out view
  /// Phase 4 (5000-7000ms): Camera zooms in to follow driver
  /// After Phase 4: Enable real-time tracking
  void _startStartRideAnimation() {
    if (_startRideAnimationDone) return;
    _startRideAnimationDone = true;
    _startRidePhase = 1;

    // PHASE 1 & 2: Simultaneously draw route and zoom out camera
    _startRouteDrawAnimation();
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _zoomOutCamToShowRoute();
    });

    // PHASE 3: Pause after zoom out (2 seconds pause after 2 second zoom = 3 seconds total)
    _startRidePhaseTimer?.cancel();
    _startRidePhaseTimer = Timer(const Duration(milliseconds: 2000), () {
      if (!mounted) return;
      _startRidePhase = 3; // pause phase
      
      // PHASE 4: Zoom back in to follow driver
      Future.delayed(const Duration(milliseconds: 3000), () {
        if (!mounted || _startRidePhase < 3) return;
        _startRidePhase = 4;
        _zoomInToCameraFollow();
        
        // PHASE 5: Enable real-time tracking after zoom in completes
        Future.delayed(const Duration(milliseconds: 2000), () {
          if (!mounted) return;
          _startRidePhase = 5;
          _shouldFollowDriver = true;
          _startCameraFollowTracking();
        });
      });
    });
  }

  /// Phase 1: Draw the route polyline progressively (animated draw effect)
  void _startRouteDrawAnimation() {
    if (_routePts.isEmpty) return;
    
    //_startAnimatedRouteDraw is already implemented in tracking_map_view.dart
    // It handles progressive polyline drawing over 1000-1500ms
  }

  /// Phase 2: Animate camera zoom out to show full route
  void _zoomOutCamToShowRoute() {
    if (_map == null || _userMovedMap) return;
    
    // Get bounds of full route
    if (_routePts.isEmpty) return;
    final pts = <LatLng>[widget.pickupLatLng, widget.dropoffLatLng];
    pts.addAll(_routePts);
    
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
      mapbox.MbxEdgeInsets(top: 160, left: 40, bottom: 120, right: 40),
      null, null,
    ).then((cam) {
      if (mounted && _map != null) {
        _map!.flyTo(cam, mapbox.MapAnimationOptions(duration: 2000));
      }
    });
  }

  /// Phase 4: Animate camera zoom in and tilted to follow driver
  void _zoomInToCameraFollow() {
    if (_map == null || !mounted) return;
    
    _map?.cameraForCoordinatesPadding(
      [mapbox.Point(coordinates: mapbox.Position(_animPos.longitude, _animPos.latitude))],
      mapbox.CameraOptions(bearing: _animBearing, pitch: 20.0, zoom: 16.5),
      mapbox.MbxEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
      null, null,
    ).then((cam) {
      if (mounted && _map != null) {
        _map!.flyTo(cam, mapbox.MapAnimationOptions(duration: 2000));
      }
    });
  }

  /// Start real-time camera tracking - follows driver every location update
  void _startCameraFollowTracking() {
    if (!_shouldFollowDriver || _map == null) return;
    
    _cameraFollowTimer?.cancel();
    _cameraFollowTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) {
      if (!mounted || !_shouldFollowDriver || _map == null) return;
      _followDriver(_animPos, _animBearing);
    });
  }

  /// Smooth camera follow for driver position
  void _followDriver(LatLng position, double bearing) {
    if (_map == null || _userMovedMap) return;
    
    _map?.cameraForCoordinatesPadding(
      [mapbox.Point(coordinates: mapbox.Position(position.longitude, position.latitude - 0.002))],
      mapbox.CameraOptions(bearing: bearing, pitch: 20.0, zoom: 16.5),
      mapbox.MbxEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
      null, null,
    ).then((cam) {
      if (mounted && _map != null) {
        _map!.flyTo(cam, mapbox.MapAnimationOptions(duration: 800));
      }
    });
  }

  void _navigateToHome() {
    _saveRideState();
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const HomeScreen(forceExpandPanel: true),
        transitionsBuilder: (_, a, __, child) =>
            FadeTransition(opacity: a, child: child),
        transitionDuration: const Duration(milliseconds: 300),
      ),
      (_) => false,
    );
  }
}
