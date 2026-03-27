part of '../screens/rider_tracking_screen.dart';

// ════════════════════════════════════════════════════════════
//  CONTROLLER — Firebase listeners, trip phases, persistence
// ════════════════════════════════════════════════════════════

extension RiderTrackingController on _RiderTrackingScreenState {

  /// Connect to Firestore for real-time driver location and trip status.
  void _startRealTimeTracking() {
    final fsId = widget.firestoreTripId;
    if (fsId != null && fsId.isNotEmpty) {
      // Watch driver location in real time
      _driverLocSub = TripFirestoreService.watchDriverLocation(fsId).listen(
        (ll) {
          if (!mounted || _phase == _TrackPhase.completed) return;
          if (_connectionLost) setState(() => _connectionLost = false);
          _onRealDriverLocation(ll);
        },
        onError: (error) {
          debugPrint('[RiderTracking] Driver location listener error: $error');
          if (mounted && !_connectionLost) {
            setState(() => _connectionLost = true);
          }
        },
      );

      // Watch trip status changes
      _tripStatusSub = TripFirestoreService.watchTrip(fsId).listen(
        (data) {
          if (!mounted) return;
          if (data == null) {
            // Null data = temporary disconnection, do NOT cancel
            debugPrint('[RiderTracking] Trip data null — keeping last known state');
            if (!_connectionLost) setState(() => _connectionLost = true);
            return;
          }
          if (_connectionLost) setState(() => _connectionLost = false);
          _onTripStatusUpdate(data);
        },
        onError: (error) {
          debugPrint('[RiderTracking] Trip status listener error: $error');
          // Stream error = connection issue, show banner and keep retrying
          if (mounted && !_connectionLost) {
            setState(() => _connectionLost = true);
          }
        },
      );
    }

    // Also poll backend status as fallback
    final tripId = widget.tripId;
    if (tripId != null) {
      _statusPollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
        if (!mounted || _phase == _TrackPhase.completed) return;
        try {
          final status = await ApiService.getTrip(tripId);
          final st = status['status']?.toString() ?? '';
          // Successful poll — clear connection lost state
          if (_connectionLost && mounted) {
            setState(() {
              _connectionLost = false;
              _pollFailCount = 0;
            });
          }
          if (st == 'completed') {
            _statusPollTimer?.cancel();
            if (mounted && _phase != _TrackPhase.completed) {
              LocalDataService.clearActiveRide();
              setState(() => _phase = _TrackPhase.completed);
              _goToRating();
            }
          } else if (st == 'cancelled' || st == 'canceled') {
            _statusPollTimer?.cancel();
            if (mounted && !_cancelDialogShown) {
              _cancelDialogShown = true;
              _showDriverCancelledDialog();
            }
          } else if (st == 'arrived' && _phase == _TrackPhase.arriving) {
            if (mounted) setState(() => _phase = _TrackPhase.arrived);
          } else if (st == 'in_trip' &&
              (_phase == _TrackPhase.arriving || _phase == _TrackPhase.arrived)) {
            if (mounted) {
              setState(() => _phase = _TrackPhase.onTrip);
              _popOutPickupPin();
            }
          }
        } catch (_) {
          // Network error — show reconnecting banner after consecutive failures
          _pollFailCount++;
          if (_pollFailCount >= _maxPollFailsBeforeBanner && mounted && !_connectionLost) {
            setState(() => _connectionLost = true);
          }
        }
      });
    }
  }

  /// Process real-time driver location from Firestore.
  void _onRealDriverLocation(LatLng ll) {
    if (ll.latitude == 0 && ll.longitude == 0) return;

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
    }

    // Update phase and distances
    if (_phase == _TrackPhase.arriving) {
      final dist = _hav(ll, widget.pickupLatLng);
      _distanceMiles = dist;
      _etaMinutes = (dist / 0.5).ceil().clamp(1, 99);
      if (dist < 0.05) {
        setState(() => _phase = _TrackPhase.arrived);
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

    setState(() {});
    _throttleCam();
  }

  /// Process trip status changes from Firestore.
  void _onTripStatusUpdate(Map<String, dynamic> data) {
    // Start RTDB listener if we have a driverId
    final did = data['driverId']?.toString();
    if (did != null && did.isNotEmpty && _rtdbDriverId != did) {
      _startRtdbDriverListener(did);
    }

    final status = data['status']?.toString() ?? '';
    if (status == 'arrived' && _phase == _TrackPhase.arriving) {
      setState(() => _phase = _TrackPhase.arrived);
    } else if (status == 'in_trip' &&
        (_phase == _TrackPhase.arriving || _phase == _TrackPhase.arrived)) {
      setState(() => _phase = _TrackPhase.onTrip);
      _popOutPickupPin();
    } else if (status == 'completed' && _phase != _TrackPhase.completed) {
      LocalDataService.clearActiveRide();
      setState(() => _phase = _TrackPhase.completed);
      _goToRating();
    } else if (status == 'cancelled' || status == 'canceled') {
      if (!_cancelDialogShown) {
        _cancelDialogShown = true;
        _showDriverCancelledDialog();
      }
    }
  }

  /// Listen to driver GPS from Firebase RTDB for sub-200ms updates.
  void _startRtdbDriverListener(String driverId) {
    _rtdbDriverLocSub?.cancel();
    _rtdbDriverId = driverId;
    _rtdbDriverLocSub = FirebaseDatabase.instance
        .ref('drivers/$driverId/location')
        .onValue
        .listen((event) {
      if (!mounted || _phase == _TrackPhase.completed) return;
      if (event.snapshot.value == null) return;
      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) return;
      _onRealDriverLocation(LatLng(lat, lng));
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

    setState(() {});
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
      final newBrg = _bearing(_animPos, LatLng(newLat, newLng));
      _animPos = LatLng(newLat, newLng);
      _driverPos = _animPos;
      if (newBrg != 0) {
        double db = newBrg - _animBearing;
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

  void _navigateToHome() {
    _saveRideState();
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const HomeScreen(),
        transitionsBuilder: (_, a, __, child) =>
            FadeTransition(opacity: a, child: child),
        transitionDuration: const Duration(milliseconds: 300),
      ),
      (_) => false,
    );
  }
}
