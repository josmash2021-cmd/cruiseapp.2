part of '../screens/rider_tracking_screen.dart';

// ════════════════════════════════════════════════════════════
//  CONTROLLER — Firebase listeners, trip phases, persistence
// ════════════════════════════════════════════════════════════

extension _RiderTrackingController on _RiderTrackingScreenState {

  void _attachTripDocListener(
    String docId, {
    required bool isFallbackDoc,
  }) {
    final listener = TripFirestoreService.watchTrip(docId).listen(
      (data) {
        if (!mounted) return;
        if (data == null) {
          _pollFailCount++;
          debugPrint('[RiderTracking] Trip data null for $docId ($_pollFailCount/$_maxPollFailsBeforeBanner)');
          if (_pollFailCount >= _maxPollFailsBeforeBanner && !_connectionLost && !NetworkService().isOnline) {
            _setState(() => _connectionLost = true);
          }
          return;
        }
        _pollFailCount = 0;
        if (_connectionLost) _setState(() => _connectionLost = false);
        // Fix 4: Firestore recovered — restore normal 8s polling interval
        _statusPollTimer?.cancel();
        _statusPollTimer = Timer.periodic(const Duration(seconds: 8), (_) {
          _pollBackendTripStatus();
        });
        _onTripStatusUpdate(data);
      },
      onError: (error) {
        debugPrint('[RiderTracking] Trip status listener error for $docId: $error');
        _pollFailCount++;
        if (mounted && _pollFailCount >= _maxPollFailsBeforeBanner && !_connectionLost) {
          _setState(() => _connectionLost = true);
        }
        // Fix 4: Firestore down → poll backend every 3s (instead of 8s) until recovered
        if (mounted && _phase != _TrackPhase.completed) {
          _statusPollTimer?.cancel();
          _statusPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
            _pollBackendTripStatus();
          });
        }
      },
    );

    if (isFallbackDoc) {
      _fallbackTripStatusSub?.cancel();
      _fallbackTripStatusSub = listener;
    } else {
      _tripStatusSub?.cancel();
      _tripStatusSub = listener;
    }
  }

  Future<void> _pollBackendTripStatus() async {
    final tripId = widget.tripId;
    if (!mounted || tripId == null || _phase == _TrackPhase.completed) return;
    try {
      final data = await ApiService.getDispatchStatus(tripId);
      if (!mounted || data.isEmpty) return;
      final status = (data['status']?.toString() ?? '').trim().toLowerCase();
      if (status.isEmpty || status == 'error') return;

      final tripData = data['trip'];
      if (tripData is Map) {
        final merged = Map<String, dynamic>.from(tripData.cast<String, dynamic>());
        merged.putIfAbsent('status', () => data['status']);
        if (status == 'completed' ||
            status == 'cancelled' ||
            status == 'canceled' ||
            status == 'arrived' ||
            status == 'driver_arrived' ||
            status == 'in_trip' ||
            status == 'in_progress') {
          debugPrint('[RiderTracking] Backend poll found status=$status');
          _onTripStatusUpdate(merged);
        }
        return;
      }

      if (status == 'completed' || status == 'cancelled' || status == 'canceled') {
        debugPrint('[RiderTracking] Backend poll found terminal status=$status');
        _onTripStatusUpdate({'status': status});
      }
    } catch (e) {
      debugPrint('[RiderTracking] Backend poll error: $e');
    }
  }

  /// Connect to Firestore for trip status and RTDB for live driver movement.
  void _startRealTimeTracking() {
    final tripId = widget.tripId;
    final sqlDocId = tripId != null ? 'sql_$tripId' : null;
    final fallbackDocId = widget.firestoreTripId;

    if (tripId != null) {
      _attachTripDocListener(sqlDocId!, isFallbackDoc: false);

      _statusPollTimer?.cancel();
      _statusPollTimer = Timer.periodic(
        const Duration(seconds: 8),
        (_) => _pollBackendTripStatus(),
      );
      unawaited(_pollBackendTripStatus());
    } else {
      _statusPollTimer?.cancel();
    }

    if (fallbackDocId != null &&
        fallbackDocId.isNotEmpty &&
        fallbackDocId != sqlDocId) {
      _attachTripDocListener(fallbackDocId, isFallbackDoc: true);
    } else {
      _fallbackTripStatusSub?.cancel();
      _fallbackTripStatusSub = null;
    }

    if (tripId != null) {
      debugPrint('[RiderTracking] Watching sql_$tripId for status updates');
    } else if (fallbackDocId != null && fallbackDocId.isNotEmpty) {
      _attachTripDocListener(fallbackDocId, isFallbackDoc: false);
    }

    // Start RTDB driver location listener immediately if driverId is known
    // (don't wait for Firestore to deliver it — avoids false "connection lost")
    final did = widget.driverId;
    if (did != null && did.isNotEmpty && _rtdbDriverId != did) {
      _startRtdbDriverListener(did);
    }

    // Start chase camera follow timer (backs up per-GPS-update follow)
    _startCameraFollowTracking();

    // Periodically persist ride state so app resumption restores correct position
    _rideSaveTimer?.cancel();
    _rideSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && _phase != _TrackPhase.completed) _saveRideState();
    });

    // Fallback: if no RTDB GPS arrives within 5s during arriving phase,
    // fetch approach route using the driver's last known Firestore position.
    if (_phase == _TrackPhase.arriving && !_approachRouteFetched) {
      _gpsFallbackTimer?.cancel();
      _gpsFallbackTimer = Timer(const Duration(seconds: 5), () {
        if (!mounted || _phase != _TrackPhase.arriving) return;
        if (_approachRouteFetched || _approachRouteFetching) return;
        // Use persisted driver position if available
        if (_driverPos.latitude != 0 && _driverPos.longitude != 0) {
          debugPrint('[RiderTracking] No RTDB GPS in 5s — using persisted driver pos for approach route');
          _onRealDriverLocation(_driverPos);
        } else {
          // Last resort: fetch driver position from backend
          _fetchDriverPositionFallback();
        }
      });
    }
  }

  /// Fetch driver position from backend as a last resort when RTDB has no data.
  Future<void> _fetchDriverPositionFallback() async {
    final tripId = widget.tripId;
    if (tripId == null) return;
    try {
      final data = await ApiService.getDispatchStatus(tripId);
      final tripData = data['trip'] as Map<String, dynamic>?;
      if (tripData == null) return;
      final driverLat = (tripData['driver_lat'] as num?)?.toDouble();
      final driverLng = (tripData['driver_lng'] as num?)?.toDouble();
      if (driverLat != null && driverLng != null && driverLat != 0 && driverLng != 0) {
        debugPrint('[RiderTracking] Fallback: got driver pos from backend ($driverLat, $driverLng)');
        if (mounted) _onRealDriverLocation(LatLng(driverLat, driverLng));
      }
    } catch (e) {
      debugPrint('[RiderTracking] Fallback driver pos fetch failed: $e');
    }
  }

  /// Process real-time driver location from RTDB.
  void _onRealDriverLocation(LatLng ll, {double? bearing, double? speed}) {
    if (ll.latitude == 0 && ll.longitude == 0) return;
    // Validate bearing — NaN/Infinity would break rotation interpolation
    if (bearing != null && (bearing.isNaN || bearing.isInfinite)) bearing = null;
    if (speed != null && (speed.isNaN || speed.isInfinite || speed < 0)) speed = null;
    // Always wake up the ticker on new GPS data — restarts if idle or stopped.
    _interpIdle = false;
    if (_interpTicker != null && !_interpTicker!.isActive) {
      _interpTicker!.start();
    }

    // Uber-style: fetch approach route (driver→pickup) on first GPS during arriving
    if (_phase == _TrackPhase.arriving && !_approachRouteFetched && !_approachRouteFetching) {
      unawaited(_fetchApproachRoute(ll));
    }

    // Always try to snap GPS onto the route polyline.
    // Only fall back to raw GPS lerp when we truly have no route.
    if (_segDist.isNotEmpty && _routePts.length >= 2) {
      final projectedM = _projectOntoRoute(ll);
      // Accept projection when close enough to route (< 150m lateral)
      final snappedPos = _posAtDistUltraSmooth(projectedM.clamp(0.0, _segDist.last)).$1;
      final lateralM = _hav(ll, snappedPos) * 1609.34;
      if (lateralM < 150) {
        _offRouteCount = 0; // back on route
        final clampedM = projectedM.clamp(0.0, _segDist.last);
        if (clampedM >= _traveledM - 5) {
          final newTarget = math.max(clampedM, _traveledM);
          // Use real driver speed from RTDB when available (most accurate).
          // Fall back to calculated velocity from GPS deltas.
          final now = DateTime.now();
          final dtSec = now.difference(_lastGpsTime).inMilliseconds / 1000.0;
          if (speed != null && speed > 0.1) {
            // Real driver speed — smooth with 30/70 blend for stability
            final realVel = speed.clamp(0.0, 35.0);
            _velocityMps = _velocityMps * 0.3 + realVel * 0.7;
          } else if (dtSec > 0.05 && dtSec < 5.0) {
            final distDelta = newTarget - _tgtTraveledM;
            if (distDelta > 0) {
              // Calculated velocity — cap to prevent spikes
              final newVel = (distDelta / dtSec).clamp(0.0, 35.0);
              _velocityMps = _velocityMps * 0.4 + newVel * 0.6;
            }
          }
          _lastGpsTime = now;
          _tgtTraveledM = newTarget;
        }
        _directTargetPos = null;
        _directTargetBearing = null;
      } else {
        // Too far from route — use raw GPS lerp as fallback
        _directTargetPos = ll;
        _directTargetBearing = bearing;
        // Reroute after 3 consecutive off-route GPS updates (~3-5s)
        // Only during active trip phases (not arriving/arrived)
        _offRouteCount++;
        final isOnTrip = _phase == _TrackPhase.onTrip || _phase == _TrackPhase.nearDestination;
        if (_offRouteCount >= 3 && !_rerouteInProgress && isOnTrip) {
          _rerouteFromCurrentPos(ll);
        }
      }
    } else {
      // No route available — use raw GPS lerp
      _directTargetPos = ll;
      _directTargetBearing = bearing;
    }

    // Update phase and distances
    if (_phase == _TrackPhase.arriving) {
      final dist = _hav(ll, widget.pickupLatLng);
      // Use remaining route distance (road) when available, fallback to haversine
      if (_segDist.isNotEmpty && _traveledM >= 0) {
        final remainM = (_segDist.last - _traveledM).clamp(0.0, _segDist.last);
        _distanceMiles = remainM / 1609.34;
      } else {
        _distanceMiles = dist;
      }
      // Use real driver velocity when available, then traffic-aware route duration, then distance fallback
      if (_velocityMps > 3.0) {
        final remainM = _distanceMiles * 1609.34;
        _etaMinutes = (remainM / _velocityMps / 60.0).ceil().clamp(1, 99);
      } else if (_routeDurationSec != null && _routeDurationSec! > 0 && _segDist.isNotEmpty && _segDist.last > 0) {
        // Scale route duration by fraction of distance remaining
        final fraction = ((_segDist.last - _traveledM) / _segDist.last).clamp(0.0, 1.0);
        _etaMinutes = (_routeDurationSec! * fraction / 60.0).ceil().clamp(1, 99);
      } else {
        _etaMinutes = (_distanceMiles / 0.4).ceil().clamp(1, 99);
      }
      // Phase transitions (arriving→arrived, arrived→onTrip) are ONLY driven
      // by backend status updates in _onTripStatusUpdate(). Never auto-transition
      // based on GPS proximity — that caused false "driver arrived" triggers.
    } else if (_phase == _TrackPhase.onTrip || _phase == _TrackPhase.nearDestination) {
      final dist = _hav(ll, widget.dropoffLatLng);
      // Use remaining route distance (road) when available, fallback to haversine
      if (_segDist.isNotEmpty && _traveledM >= 0) {
        final remainM = (_segDist.last - _traveledM).clamp(0.0, _segDist.last);
        _distanceMiles = remainM / 1609.34;
      } else {
        _distanceMiles = dist;
      }
      // Use real driver velocity for ETA when available (> 3 m/s ≈ walking speed),
      // then traffic-aware route duration, then distance-based fallback
      if (_velocityMps > 3.0) {
        final remainM = _distanceMiles * 1609.34;
        _etaMinutes = (remainM / _velocityMps / 60.0).ceil().clamp(1, 99);
      } else if (_routeDurationSec != null && _routeDurationSec! > 0 && _segDist.isNotEmpty && _segDist.last > 0) {
        final fraction = ((_segDist.last - _traveledM) / _segDist.last).clamp(0.0, 1.0);
        _etaMinutes = (_routeDurationSec! * fraction / 60.0).ceil().clamp(1, 99);
      } else {
        // Fallback: 0.4 mi/min ≈ 24 mph average urban
        _etaMinutes = (_distanceMiles / 0.4).ceil().clamp(1, 99);
      }
      // Transition to nearDestination when ETA <= 2 min
      if (_etaMinutes <= 2 && _phase == _TrackPhase.onTrip) {
        _setState(() => _phase = _TrackPhase.nearDestination);
      } else if (_etaMinutes > 2 && _phase == _TrackPhase.nearDestination) {
        // Transition back if driver moved away (re-routing)
        _setState(() => _phase = _TrackPhase.onTrip);
      }
    }

    // Throttle UI rebuilds to max 3/sec — car annotation is updated
    // directly in _updateCarSmooth() without needing widget rebuild.
    final now2 = DateTime.now();
    if (now2.difference(_lastUiRebuild).inMilliseconds > 333) {
      _lastUiRebuild = now2;
      _setState(() {});
    }
    _throttleCam();
  }

  /// Fetch a new route from the driver's current position to the dropoff
  /// and redraw with animated transition.
  Future<void> _rerouteFromCurrentPos(LatLng driverPos) async {
    _rerouteInProgress = true;
    debugPrint('[RiderTracking] Rerouting from driver pos (${driverPos.latitude}, ${driverPos.longitude})');
    try {
      final ds = DirectionsService(ApiKeys.webServices);
      final result = await ds.getRoute(
        origin: driverPos,
        destination: widget.dropoffLatLng,
      );
      if (result == null || result.points.length < 2 || !mounted) return;

      // Update traffic-aware route duration for ETA calculation
      _routeDurationSec = result.durationSeconds;

      // Fade out old route, then draw new one
      await _fadeAndRedrawRoute(result.points, driverPos);
    } catch (e) {
      debugPrint('[RiderTracking] Reroute error: $e');
    } finally {
      _rerouteInProgress = false;
      _offRouteCount = 0;
    }
  }

  /// Fade old route and animate new route drawing.
  Future<void> _fadeAndRedrawRoute(List<LatLng> newPoints, LatLng driverPos) async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null) return;

    // 1) Fade out existing route over 400ms
    if (_remainingRouteAnnot != null) {
      final startTime = DateTime.now();
      const fadeDuration = 400;
      final completer = Completer<void>();
      Timer.periodic(const Duration(milliseconds: 16), (timer) {
        if (!mounted) { timer.cancel(); if (!completer.isCompleted) completer.complete(); return; }
        final elapsed = DateTime.now().difference(startTime).inMilliseconds;
        final t = (elapsed / fadeDuration).clamp(0.0, 1.0);
        try {
          polyMgr.update(_remainingRouteAnnot!..lineOpacity = 1.0 - t);
        } catch (_) {}
        if (t >= 1.0) {
          timer.cancel();
          try { polyMgr.delete(_remainingRouteAnnot!); } catch (_) {}
          _remainingRouteAnnot = null;
          if (!completer.isCompleted) completer.complete();
        }
      });
      await completer.future;
    }

    // Also remove dimmed route
    if (_dimmedRouteAnnot != null) {
      try { polyMgr.delete(_dimmedRouteAnnot!); } catch (_) {}
      _dimmedRouteAnnot = null;
    }

    // 2) Update route data
    _routePts = newPoints;
    _buildSegDist();
    _traveledM = 0;
    _tgtTraveledM = 0;
    _velocityMps = 0;
    _directTargetPos = null;
    _directTargetBearing = null;

    // 3) Draw dimmed background route for the new path
    final allCoords = _routePts.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    try {
      _dimmedRouteAnnot = await polyMgr.create(mapbox.PolylineAnnotationOptions(
        geometry: mapbox.LineString(coordinates: allCoords),
        lineColor: const Color(0xFFFFD700).withValues(alpha: 0.20).toARGB32(),
        lineWidth: 5.0,
        lineJoin: mapbox.LineJoin.ROUND,
      ));
    } catch (_) {}

    // 4) Animate new route drawing on top
    _routeDrawDone = false;
    _startAnimatedRouteDraw();
  }

  /// Fetch road-following route from driver's current position to pickup
  /// for Uber-style approach visualization during arriving phase.
  Future<void> _fetchApproachRoute(LatLng driverPos) async {
    if (_approachRouteFetching || _approachRouteFetched) return;
    _approachRouteFetching = true;
    debugPrint('[RiderTracking] Fetching approach route: driver(${driverPos.latitude.toStringAsFixed(5)},${driverPos.longitude.toStringAsFixed(5)}) → pickup');
    try {
      final ds = DirectionsService(ApiKeys.webServices);
      final result = await ds.getRoute(
        origin: driverPos,
        destination: widget.pickupLatLng,
      );
      if (result == null || result.points.length < 2 || !mounted) {
        _approachRouteFetching = false;
        return;
      }
      _approachRouteFetched = true;
      _approachRouteFetching = false;

      // Keep trip route as dimmed background (already drawn in _updateStaticAnnotationsOnce).
      // Set approach route as the active route for car tracking.
      _routePts = result.points;
      _buildSegDist();
      _traveledM = 0;
      _tgtTraveledM = 0;
      _velocityMps = 0;
      _directTargetPos = null;
      _directTargetBearing = null;

      // Initial ETA from approach route — prefer traffic-aware duration from API
      _distanceMiles = result.distanceMeters / 1609.34;
      _routeDurationSec = result.durationSeconds;
      if (_routeDurationSec != null && _routeDurationSec! > 0) {
        _etaMinutes = (_routeDurationSec! / 60.0).ceil().clamp(1, 99);
      } else {
        _etaMinutes = (_distanceMiles / 0.4).ceil().clamp(1, 99);
      }

      _setState(() {});

      // The trip route (pickup→dropoff) stays as the dimmed background.
      // Draw the approach route (driver→pickup) as a second dimmed line,
      // then animate the gold route on top.
      final polyMgr = _polylineAnnotMgr;
      if (polyMgr != null) {
        final allCoords = _routePts.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        // Don't remove the existing dimmed route (it's the trip route pickup→dropoff).
        // Create approach dimmed line separately.
        try {
          if (_approachAnnot != null) {
            try { polyMgr.delete(_approachAnnot!); } catch (_) {}
            _approachAnnot = null;
          }
          _approachAnnot = await polyMgr.create(mapbox.PolylineAnnotationOptions(
            geometry: mapbox.LineString(coordinates: allCoords),
            lineColor: const Color(0xFFFFD700).withValues(alpha: 0.20).toARGB32(),
            lineWidth: 5.0,
            lineJoin: mapbox.LineJoin.ROUND,
          ));
        } catch (_) {}
      }

      // Animate the gold route draw (approach route)
      _routeDrawDone = false;
      _startAnimatedRouteDraw();

      // Fit camera to show driver + pickup + dropoff
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) _fitRouteBounds();
      });

      debugPrint('[RiderTracking] Approach route ready: ${_routePts.length} pts, ${_distanceMiles.toStringAsFixed(1)} mi, ETA $_etaMinutes min');
    } catch (e) {
      debugPrint('[RiderTracking] Approach route fetch error: $e');
      _approachRouteFetching = false;
    }
  }

  /// Process trip status changes from Firestore.
  void _onTripStatusUpdate(Map<String, dynamic> data) {
    // Start RTDB listener if we have a driverId
    var did = data['driverId']?.toString() ?? data['driver_id']?.toString() ?? '';
    // Strip legacy "sql_" prefix so RTDB path matches driver_locations/{intId}
    if (did.startsWith('sql_')) did = did.substring(4);
    if (did.isNotEmpty && _rtdbDriverId != did) {
      _startRtdbDriverListener(did);
    }

    // Update driver photo URL with robust recovery chain fields from Firestore.
    final driverObj = data['driver'];
    final driverMap = driverObj is Map ? driverObj : null;
    final fsPhoto = _normalizeRemotePhotoUrl(
      data['driverPhotoUrl']?.toString() ??
          data['driver_photo_url']?.toString() ??
          data['photo_url']?.toString() ??
          data['profile_photo_url']?.toString() ??
          data['driverProfilePhoto']?.toString() ??
          data['driver_profile_photo']?.toString() ??
          driverMap?['photo_url']?.toString() ??
          driverMap?['photoUrl']?.toString() ??
          driverMap?['profile_photo_url']?.toString() ??
          driverMap?['profilePhotoUrl']?.toString(),
    );
    if (fsPhoto != null && fsPhoto.isNotEmpty && fsPhoto != _driverPhotoUrl) {
      _setState(() => _driverPhotoUrl = fsPhoto);
    } else if ((fsPhoto == null || fsPhoto.isEmpty) && (_driverPhotoUrl == null || _driverPhotoUrl!.isEmpty)) {
      // Trip doc has no photo URL — fetch directly from driver's user doc in Firestore.
      final dId = widget.driverId ?? did;
      if (dId.isNotEmpty) {
        unawaited(_fetchDriverPhotoFromUserDoc(dId));
      }
    }

    final rawStatus = data['status']?.toString() ?? '';
    // Normalise to canonical values — backend firestore_sync already canonicalises,
    // but keep aliases here as a safety net for any legacy documents.
    final statusAliases = <String, String>{
      'driver_arrived': 'arrived',
      'arrived_pickup': 'arrived',
      'arrived_at_pickup': 'arrived',
      'in_progress': 'in_trip',
      'rider_onboard': 'in_trip',
      'on_trip': 'in_trip',
      'trip_started': 'in_trip',
      'canceled': 'cancelled',
    };
    final status = statusAliases[rawStatus.trim().toLowerCase()] ??
        rawStatus.trim().toLowerCase();

    final isArrivedStatus = status == 'arrived';
    final isInTripStatus = status == 'in_trip';
    final isCompletedStatus = status == 'completed';
    // Only trust the explicit status field for cancellation — never timestamps alone.
    final isCancelledStatus = status == 'cancelled';

    debugPrint('[RiderTracking] Firestore status update: "$rawStatus" normalized="$status" (phase=$_phase, driverId=$did)');
    if (isArrivedStatus && _phase == _TrackPhase.arriving) {
      _setState(() {
        _phase = _TrackPhase.arrived;
        _etaMinutes = 0;
        _distanceMiles = 0;
      });
      _saveRideState();
      // FIX 2: Start the pulsing dot animation and handle arrival visuals
      _arrivedDotPulse.repeat(reverse: true);
      // Fade route polyline and zoom camera to driver location
      _handleDriverArrived();
      _showRiderConfirmPickup();
      if (!_arrivedNotifSent) {
        _arrivedNotifSent = true;
        _sendRideNotification(
          'Your driver has arrived',
          '${widget.driverName.split(' ').first} is waiting at the pickup spot in a ${widget.vehicleColor} ${widget.vehicleModel}.',
        );
      }
    } else if (isInTripStatus &&
        (_phase == _TrackPhase.arriving || _phase == _TrackPhase.arrived)) {
      // Swap from approach route (driver→pickup) to trip route (pickup→dropoff)
      if (_tripRoutePts.isNotEmpty) {
        _routePts = _tripRoutePts;
        _buildSegDist();
      }
      // Reset traveled distance for the new trip leg and recalculate ETA
      _traveledM = 0;
      _tgtTraveledM = 0;
      _velocityMps = 0;
      _approachRouteFetched = false;
      // Reset route duration — will be set on next route fetch
      _routeDurationSec = null;
      if (_segDist.isNotEmpty) {
        final totalRouteM = _segDist.last;
        _distanceMiles = totalRouteM / 1609.34;
        _etaMinutes = (_distanceMiles / 0.4).ceil().clamp(1, 99);
      }
      _setState(() {
        _phase = _TrackPhase.onTrip;
        _tripJustStarted = true;
      });
      // Re-enable camera tracking (disabled during arrived phase)
      _shouldFollowDriver = true;
      _startCameraFollowTracking();
      _saveRideState();
      _tripStartedTimer?.cancel();
      _tripStartedTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) _setState(() => _tripJustStarted = false);
      });
      _arrivedDotPulse.stop();
      _popOutPickupPin();
      // Reset guard so animation always runs fresh on arriving→onTrip transition
      _startRideAnimationDone = false;
      _startStartRideAnimation();
    } else if (isInTripStatus &&
        _phase == _TrackPhase.nearDestination) {
      // Already near destination — don't reset to onTrip
      _arrivedDotPulse.stop(); // Stop pulsing dot animation
      _popOutPickupPin();
      // FIX 3 & 4: Start the route animation and camera phases when starting ride
      _startRideAnimationDone = false;
      _startStartRideAnimation();
    } else if (isCompletedStatus && _phase != _TrackPhase.completed) {
      unawaited(LocalDataService.clearActiveRide());
      _setState(() => _phase = _TrackPhase.completed);
      _arrivedDotPulse.stop();
      // Save trip chat to inbox before navigating away
      _saveChatToInbox();
      // Let the rider see the "Trip completed" state briefly before rating
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) _goToRating();
      });
    } else if (isCancelledStatus) {
      // Guard: if thet trip is already in an active phase (driver accepted,
      // arriving, arrived, in trip) ignore a stale "cancelled" status that
      // can appear from Firestore merge artefacts or race conditions.
      if (_phase == _TrackPhase.arriving ||
          _phase == _TrackPhase.arrived ||
          _phase == _TrackPhase.onTrip ||
          _phase == _TrackPhase.nearDestination) {
        debugPrint('[RiderTracking] Ignoring cancelled status while in active phase $_phase');
        return;
      }

      final cancelledBy =
          (data['cancelledBy'] ??
                  data['canceledBy'] ??
                  data['cancelled_by'] ??
                  data['canceled_by'] ??
                  '')
              .toString()
              .trim()
              .toLowerCase();
      final cancellationReason =
          (data['cancellationReason'] ??
                  data['cancellation_reason'] ??
                  data['cancelReason'] ??
                  data['cancel_reason'] ??
                  '')
              .toString()
              .trim()
              .toLowerCase();

      final cancelledByDriver =
          cancelledBy == 'driver' || cancellationReason.contains('driver');
      final cancelledByRider =
          cancelledBy == 'rider' ||
          cancelledBy == 'passenger' ||
          cancellationReason.contains('rider') ||
          cancellationReason.contains('passenger') ||
          cancellationReason.contains('user_cancelled');

      if (cancelledByRider) {
        // Rider already initiated the cancellation flow elsewhere.
        return;
      }

      if (!_cancelDialogShown) {
        _cancelDialogShown = true;
        _showDriverCancelledDialog(
          message: cancelledByDriver
              ? null
              : S.of(context).tripCancelledByOperator,
        );
      }
    }
  }

  /// Show the rider confirmation pickup overlay when driver has arrived.
  void _showRiderConfirmPickup() {
    if (!mounted || _confirmPickupShown) return;
    _confirmPickupShown = true;
    final vehicleDesc =
        '${widget.vehicleColor} ${widget.vehicleMake} ${widget.vehicleModel}'.trim();
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, __, ___) => RiderConfirmPickupScreen(
          driverName: widget.driverName,
          vehicleDesc: vehicleDesc,
          firestoreTripId: widget.firestoreTripId,
          tripId: widget.tripId,
          driverPhotoUrl: _driverPhotoUrl ?? _normalizeRemotePhotoUrl(widget.driverPhotoUrl),
          driverId: widget.driverId,
          driverRating: widget.driverRating,
          vehiclePlate: widget.vehiclePlate,
          onConfirmed: () {
            _confirmPickupShown = false;
            if (mounted) Navigator.of(context).pop();
          },
        ),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut), child: child),
        transitionDuration: const Duration(milliseconds: 500),
        reverseTransitionDuration: const Duration(milliseconds: 600),
      ),
    );
  }

  /// Listen to driver GPS from Firebase RTDB for sub-200ms updates.
  void _startRtdbDriverListener(String driverId) async {
    _rtdbDriverLocSub?.cancel();
    _rtdbDriverId = driverId;
    // Ensure Firebase Auth so RTDB rules (auth != null) pass
    if (FirebaseAuth.instance.currentUser == null) {
      try { await FirebaseAuth.instance.signInAnonymously(); }
      catch (_) { debugPrint('[RiderTracking] Firebase anonymous auth failed'); }
    }
    DateTime? lastRtdbUpdate;
    _rtdbDriverLocSub = FirebaseDatabase.instance
        .ref('driver_locations/$driverId')
        .onValue
        .listen((event) {
      if (!mounted || _phase == _TrackPhase.completed) return;
      if (event.snapshot.value == null) {
        // Driver location cleared — trip may be completed or cancelled
        debugPrint('[RiderTracking] RTDB driver location null — checking trip status');
        _checkTripStatusFallback();
        // Retry after 5s in case Firestore write is delayed
        Future.delayed(const Duration(seconds: 5), () {
          if (mounted && _phase != _TrackPhase.completed) {
            _checkTripStatusFallback();
          }
        });
        return;
      }
      // Reset stale timer on every location update
      _staleDriverTimer?.cancel();
      _staleDriverTimer = Timer(const Duration(seconds: 20), () {
        if (mounted && _phase != _TrackPhase.completed) {
          debugPrint('[RiderTracking] Stale driver location — checking trip status');
          _checkTripStatusFallback();
        }
      });
      // Throttle: max 8 updates/sec — more GPS data = smoother interpolation
      final now = DateTime.now();
      if (lastRtdbUpdate != null &&
          now.difference(lastRtdbUpdate!).inMilliseconds < 125) {
        return;
      }
      lastRtdbUpdate = now;
      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      final bearing = (data['bearing'] as num?)?.toDouble();
      final speed = (data['speed'] as num?)?.toDouble();
      if (lat == null || lng == null) return;
      _pollFailCount = 0;
      // Fix 3: successful update — reset fail count and restore normal 8s polling
      if (_rtdbFailCount > 0) {
        _rtdbFailCount = 0;
        _rtdbReconnectTimer?.cancel();
        _statusPollTimer?.cancel();
        _statusPollTimer = Timer.periodic(const Duration(seconds: 8), (_) {
          _pollBackendTripStatus();
        });
      }
      if (_connectionLost) _setState(() => _connectionLost = false);
      _onRealDriverLocation(LatLng(lat, lng), bearing: bearing, speed: speed);
    }, onError: (e) {
      debugPrint('[RiderTracking] RTDB stream error: $e');
      _pollFailCount++;
      _rtdbFailCount++;
      if (_pollFailCount >= _maxPollFailsBeforeBanner && mounted && !_connectionLost) {
        _setState(() => _connectionLost = true);
      }
      // Fix 3: auto-reconnect RTDB after errors with exponential back-off (max 30s)
      if (mounted && _phase != _TrackPhase.completed) {
        final delay = Duration(seconds: (_rtdbFailCount * 3).clamp(3, 30));
        debugPrint('[RiderTracking] RTDB reconnect in ${delay.inSeconds}s (attempt $_rtdbFailCount)');
        _rtdbReconnectTimer?.cancel();
        _rtdbReconnectTimer = Timer(delay, () {
          if (mounted && _phase != _TrackPhase.completed && _rtdbDriverId != null) {
            debugPrint('[RiderTracking] RTDB reconnecting to driver_locations/$_rtdbDriverId');
            _startRtdbDriverListener(_rtdbDriverId!);
          }
        });
        // Fix 4: while RTDB is down, poll backend every 3s (faster than normal 8s)
        _statusPollTimer?.cancel();
        _statusPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
          _pollBackendTripStatus();
        });
      }
    });
  }

  Future<void> _saveChatToInbox() async {
    final rideId = widget.firestoreTripId;
    if (rideId == null || rideId.isEmpty) return;
    final uid = UserSession.currentUid;
    if (uid.isEmpty) return;
    try {
      final snap = await FirebaseDatabase.instance
          .ref('chats/$rideId/messages')
          .orderByChild('timestamp')
          .get();
      if (!snap.exists) return;
      final msgs = <Map<String, dynamic>>[];
      for (final child in snap.children) {
        final val = child.value;
        if (val is Map) msgs.add(Map<String, dynamic>.from(val));
      }
      if (msgs.isEmpty) return;
      msgs.sort((a, b) =>
          (a['timestamp'] as int? ?? 0).compareTo(b['timestamp'] as int? ?? 0));
      await FirebaseFirestore.instance
          .collection('users')
          .doc('sql_$uid')
          .collection('inbox_chats')
          .doc(rideId)
          .set({
        'tripId': rideId,
        'driverId': _rtdbDriverId ?? '',
        'driverName': widget.driverName,
        'driverPhotoUrl': _driverPhotoUrl ?? widget.driverPhotoUrl ?? '',
        'lastMessage': msgs.last['text'] ?? '',
        'messageCount': msgs.length,
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(
            DateTime.now().add(const Duration(hours: 5))),
        'messages': msgs,
      });
    } catch (e) {
      debugPrint('[Inbox] save chat error: $e');
    }
  }

  void _goToRating() {
    if (!mounted) return;
    // Navigate to rating with smooth fade transition
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => RiderRatingScreen(
          driverName: widget.driverName,
          tripId: widget.tripId,
          fare: widget.price,
          driverPhotoUrl: _driverPhotoUrl ?? _normalizeRemotePhotoUrl(widget.driverPhotoUrl),
          driverUid: widget.driverId,
          dropoffLat: widget.dropoffLatLng.latitude,
          dropoffLng: widget.dropoffLatLng.longitude,
        ),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 600),
        reverseTransitionDuration: const Duration(milliseconds: 500),
      ),
    );
  }

  /// Safety fallback: one-shot Firestore read to check if trip ended.
  /// Called when RTDB location goes null or becomes stale.
  Future<void> _checkTripStatusFallback() async {
    if (!mounted || _phase == _TrackPhase.completed || _completionCheckInFlight) return;
    _completionCheckInFlight = true;
    try {
      final docIds = <String>[];
      final tripId = widget.tripId;
      if (tripId != null) {
        docIds.add('sql_$tripId');
      }
      final fallbackDocId = widget.firestoreTripId;
      if (fallbackDocId != null &&
          fallbackDocId.isNotEmpty &&
          !docIds.contains(fallbackDocId)) {
        docIds.add(fallbackDocId);
      }

      for (final docId in docIds) {
        final doc = await FirebaseFirestore.instance
            .collection('trips')
            .doc(docId)
            .get();
        if (!mounted || !doc.exists) continue;
        final data = doc.data();
        if (data == null) continue;
        final status = (data['status']?.toString() ?? '').trim().toLowerCase();
        if (status == 'completed' ||
            status == 'cancelled' ||
            status == 'canceled' ||
            status == 'in_trip' ||
            status == 'in_progress' ||
            status == 'arrived' ||
            status == 'driver_arrived' ||
            status == 'arrived_at_pickup') {
          debugPrint('[RiderTracking] Firestore fallback found status=$status on $docId');
          _onTripStatusUpdate(data);
          return;
        }
      }

      await _pollBackendTripStatus();
    } catch (e) {
      debugPrint('[RiderTracking] Fallback status check error: $e');
    } finally {
      _completionCheckInFlight = false;
    }
  }

  void _sendDriverGreeting() {
    if (!mounted || _greetingSent) return;
    _greetingSent = true;
    final firstName = widget.driverName.split(' ').first;
    final greetingText =
        'Hello! I\'m $firstName, your private driver. I\'ll be arriving shortly.';

    // Write greeting to RTDB chat so it appears in the chat screen
    // (not as a system notification that shows on top of the app).
    final rideId = widget.firestoreTripId;
    final driverId = widget.driverId;
    if (rideId != null && rideId.isNotEmpty) {
      ChatService().sendMessage(
        rideId: rideId,
        senderId: driverId?.toString() ?? 'driver',
        senderRole: 'driver',
        text: greetingText,
      );
    }
  }

  void _sendRideNotification(String title, String body) {
    NotificationService.show(id: title.hashCode, title: title, body: body);
    LocalDataService.addNotification(title: title, message: body, type: 'ride');
  }

  /// Initialize from persisted state or start fresh
  Future<void> _initFromPersistence() async {
    final activeRide = await LocalDataService.getActiveRide();
    if (activeRide == null) {
      // No persisted ride - initialize fresh, but use backend status as fallback
      _applyInitialStatus();
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

    // Restore phase FIRST — _initRoute() uses _phase to decide arriving vs onTrip setup,
    // so it must be set before the route emptiness check below.
    if (activeRide.phase != null) {
      switch (activeRide.phase) {
        case 'arriving':
          _phase = _TrackPhase.arriving;
        case 'arrived':
          _phase = _TrackPhase.arrived;
        case 'onTrip':
          _phase = _TrackPhase.onTrip;
        case 'nearDestination':
          _phase = _TrackPhase.nearDestination;
        default:
          _phase = _TrackPhase.arriving;
      }
    }

    // If persisted phase seems behind the backend status, upgrade it.
    // e.g., persistence says 'arriving' but backend says 'in_trip'
    final rawInit = (widget.initialStatus ?? '').toLowerCase().trim();
    final initAliases = <String, String>{
      'driver_arrived': 'arrived', 'arrived_pickup': 'arrived', 'arrived_at_pickup': 'arrived',
      'in_progress': 'in_trip', 'rider_onboard': 'in_trip', 'on_trip': 'in_trip', 'trip_started': 'in_trip',
    };
    final s = initAliases[rawInit] ?? rawInit;
    final isBackendInTrip = s == 'in_trip';
    final isBackendArrived = s == 'arrived';
    if (isBackendInTrip && (_phase == _TrackPhase.arriving || _phase == _TrackPhase.arrived)) {
      _phase = _TrackPhase.onTrip;
    } else if (isBackendArrived && _phase == _TrackPhase.arriving) {
      _phase = _TrackPhase.arrived;
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
    // Do NOT force raw pin coordinates onto the route — Mapbox Directions API
    // already snaps start/end to the nearest road. Replacing them with the
    // user's raw tap coordinates creates off-road straight-line segments.

    _buildSegDist();

    // Restore traffic-aware route duration for ETA calculation
    _routeDurationSec = activeRide.routeDurationSec;

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
      // No persisted position — hide car until first real RTDB GPS.
      // The car IS the driver; it must appear at the driver's actual location.
      _driverPos = const LatLng(0, 0);
      _animPos = _driverPos;
    }

    // Calculate remaining distance — use route duration when available
    double remainingM = _segDist.isNotEmpty ? _segDist.last - _traveledM : 0;
    _distanceMiles = remainingM / 1609.34;
    if (_routeDurationSec != null && _routeDurationSec! > 0 && _segDist.isNotEmpty && _segDist.last > 0) {
      final fraction = (remainingM / _segDist.last).clamp(0.0, 1.0);
      _etaMinutes = (_routeDurationSec! * fraction / 60.0).ceil().clamp(1, 99);
    } else {
      _etaMinutes = (_distanceMiles / 0.4).ceil().clamp(1, 99);
    }

    // Arriving phase: keep trip route visible as dimmed background.
    // The approach route (driver→pickup) will overlay on first RTDB GPS update.
    if (_phase == _TrackPhase.arriving) {
      if (_tripRoutePts.isEmpty && _routePts.isNotEmpty) {
        _tripRoutePts = List.from(_routePts);
      }
      // Keep _routePts as the trip route so it shows on the map (dimmed)
      _traveledM = 0;
      _tgtTraveledM = 0;
      if (activeRide.driverLat != null && activeRide.driverLng != null &&
          activeRide.driverLat! != 0 && activeRide.driverLng! != 0) {
        _driverPos = LatLng(activeRide.driverLat!, activeRide.driverLng!);
        _animPos = _driverPos;
      }
      // Show distance from driver to pickup, not full trip distance
      if (_driverPos.latitude != 0 && _driverPos.longitude != 0) {
        _distanceMiles = _hav(_driverPos, widget.pickupLatLng);
      } else {
        _distanceMiles = 0;
      }
      // Prefer persisted traffic-aware ETA; fall back to distance-based estimate
      final storedEta = activeRide.etaMinutes;
      if (storedEta != null && storedEta > 0) {
        _etaMinutes = storedEta.clamp(1, 99);
      } else if (_routeDurationSec != null && _routeDurationSec! > 0) {
        _etaMinutes = (_routeDurationSec! / 60.0).ceil().clamp(1, 99);
      } else {
        _etaMinutes = (_distanceMiles / 0.4).ceil().clamp(1, 99);
      }
    }

    if (_phase == _TrackPhase.arrived) {
      _arrivedDotPulse.repeat(reverse: true);
      _shouldFollowDriver = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _handleDriverArrived();
      });
    }

    if (!mounted) return;
    _setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fitAllPoints();
    });
  }

  /// Use the backend trip status (passed via widget.initialStatus) to set
  /// the correct phase when local persistence is unavailable (reinstall, etc.)
  void _applyInitialStatus() {
    final raw = (widget.initialStatus ?? '').toLowerCase().trim();
    final aliases = <String, String>{
      'driver_arrived': 'arrived', 'arrived_pickup': 'arrived', 'arrived_at_pickup': 'arrived',
      'in_progress': 'in_trip', 'rider_onboard': 'in_trip', 'on_trip': 'in_trip', 'trip_started': 'in_trip',
    };
    final s = aliases[raw] ?? raw;
    if (s == 'in_trip') {
      _phase = _TrackPhase.onTrip;
    } else if (s == 'arrived') {
      _phase = _TrackPhase.arrived;
    }
    // else keep default = arriving
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
      case _TrackPhase.nearDestination:
        phaseStr = 'nearDestination';
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
      driverPhotoUrl: _driverPhotoUrl ?? activeRide.driverPhotoUrl,
      driverId: activeRide.driverId,
      etaMinutes: _etaMinutes,
      routeDurationSec: _routeDurationSec,
    );

    await LocalDataService.setActiveRide(updatedRide);
  }

  // Called every vsync frame via Ticker — GPU-synchronized, zero-jolt movement.
  // Uses delta-time for frame-rate independent animation (smooth on 30/60/120Hz).
  void _interpolate(Duration elapsed) {
    if (!mounted) return;

    // ── Compute delta-time (seconds), clamped to avoid huge jumps on resume ──
    final dtMs = (elapsed - _lastInterpElapsed).inMilliseconds.clamp(1, 100);
    _lastInterpElapsed = elapsed;
    final dt = dtMs / 1000.0;

    // Time-based factor: at 60fps gives ~base per frame; scales with any refresh rate
    double tf(double base) => 1.0 - math.pow(1.0 - base, dt * 60);

    // No route yet — use direct GPS lerp so car still moves before route arrives
    if (_segDist.isEmpty) {
      final tgt = _directTargetPos;
      if (tgt != null) {
        // First GPS: teleport car instantly to driver's real position.
        // Without this, the car would slide from (0,0) to the real location.
        if (_animPos.latitude == 0 && _animPos.longitude == 0) {
          _animPos = tgt;
          _driverPos = tgt;
          _animBearing = _directTargetBearing ?? 0;
          _driverBearing = _animBearing;
          _updateCarSmooth();
          return;
        }
        final prevPos = _animPos;
        final posFactor = tf(0.18); // smooth glide toward target
        final dLat = tgt.latitude - _animPos.latitude;
        final dLng = tgt.longitude - _animPos.longitude;
        final newLat = _animPos.latitude + dLat * posFactor;
        final newLng = _animPos.longitude + dLng * posFactor;
        _animPos = LatLng(newLat, newLng);
        _driverPos = _animPos;
        // Calculate bearing from movement direction (prev→current)
        // instead of raw GPS bearing — car always faces where it's going
        final movedEnough = (newLat - prevPos.latitude).abs() > 0.000002 ||
                            (newLng - prevPos.longitude).abs() > 0.000002;
        double targetBrg;
        if (movedEnough) {
          targetBrg = _bearing(prevPos, _animPos);
        } else {
          targetBrg = _directTargetBearing ?? _animBearing;
        }
        double d = targetBrg - _animBearing;
        if (d > 180) d -= 360;
        if (d < -180) d += 360;
        final brgFactor = tf(0.30);
        _animBearing = (_animBearing + d * brgFactor) % 360;
        _driverBearing = _animBearing;
        // Only idle when trip is completed — never stop during active phases
        final isActive = _phase != _TrackPhase.completed;
        if (!isActive && dLat.abs() < 0.0000005 && dLng.abs() < 0.0000005 && d.abs() < 0.1) {
          _interpIdle = true;
          _interpTicker?.stop();
          return;
        }
        _updateCarSmooth();
      }
      return;
    }

    // ── CONSTANT-VELOCITY advance (glass-smooth, ZERO jumps) ──
    // First GPS with a route: teleport to projected position on route.
    if (_animPos.latitude == 0 && _animPos.longitude == 0 && _tgtTraveledM > 0) {
      _traveledM = _tgtTraveledM;
      final (p, b) = _posAtDistUltraSmooth(_traveledM);
      _animPos = p;
      _animBearing = b;
      _driverPos = p;
      _driverBearing = b;
      _updateCarSmooth();
      return;
    }
    // Predict ahead using driver's real speed so car glides at same pace.
    final predicted = _tgtTraveledM + _velocityMps * 0.6;
    final effectiveTarget = math.min(predicted, _segDist.last);
    final diff = effectiveTarget - _traveledM;

    // Primary: advance at measured driver speed (m/s × dt).
    // This distributes movement EVENLY across ALL frames between GPS updates
    // instead of proportional catch-up which reaches target in 200ms then stalls.
    final velStep = _velocityMps * dt;
    // Fallback: gentle proportional correction (5%/frame at 60fps)
    // for catching up when stopped or accumulated drift.
    final corrStep = diff * tf(0.05);
    // Use whichever produces more forward movement — velocity dominates while
    // driving, correction dominates when stopped.
    if (diff > 0.05) {
      final step2 = math.max(velStep, corrStep).clamp(0.0, 12.0);
      _traveledM = math.min(_traveledM + step2, effectiveTarget);
    } else if (diff.abs() <= 0.05) {
      _traveledM = _tgtTraveledM;
    }
    // Velocity decay: retain ~99% per second — sustains glide for 5+ sec GPS gaps
    // Real driver speed is refreshed every ~1-2s from RTDB, so barely decays in practice
    _velocityMps *= math.pow(0.99, dt);

    final (pos, brg) = _posAtDistUltraSmooth(_traveledM);

    // ── Bearing: time-based rotation for smooth car nose direction ──
    double db = brg - _animBearing;
    if (db > 180) db -= 360;
    if (db < -180) db += 360;
    final brgFactor = tf(0.50);
    final newBearing = (_animBearing + db * brgFactor) % 360;

    _animPos = pos;
    _animBearing = newBearing;
    _driverPos = pos;
    _driverBearing = newBearing;

    // ── Direct-target lerp (GPS fallback — ONLY when off-route) ──
    // Off-route: position follows GPS but bearing ALWAYS follows route direction
    // so the car icon consistently faces along the gold line.
    final tgt = _directTargetPos;
    if (tgt != null) {
      final offRouteFactor = tf(0.06);
      final newLat = _animPos.latitude + (tgt.latitude - _animPos.latitude) * offRouteFactor;
      final newLng = _animPos.longitude + (tgt.longitude - _animPos.longitude) * offRouteFactor;
      _animPos = LatLng(newLat, newLng);
      _driverPos = _animPos;
      // Keep bearing from route (already set above) — don't override with GPS bearing
    }

    // Update map annotations directly — no setState needed (avoids 60fps widget rebuilds)
    _throttleBoundsFit();
    _updateCarSmooth(); // fast path: only car GeoJSON
    _updateStaticAnnotationsOnce(); // slow path: pins + route, created once
    _eraseRouteBehindCar(); // progressive route erase (throttled internally)
    _updateApproachLine(); // dashed approach line driver→pickup

    // ── Idle detection: pause ticker only when car is truly stationary ──
    // With constant-velocity interpolation the ticker must stay running
    // as long as there is ANY predicted velocity remaining.
    // NEVER idle during active phases — the ticker must be awake to process
    // the next RTDB GPS update instantly (no 1-frame delay on restart).
    final isActivePhase = _phase != _TrackPhase.completed;
    final diff2 = (_tgtTraveledM - _traveledM).abs();
    if (!isActivePhase && diff2 < 0.01 && _velocityMps < 0.3 && _directTargetPos == null) {
      _interpIdle = true;
      _interpTicker?.stop();
    }
  }

  /// ──────────────────────────────────────────────────────────────────────────
  /// FIX 3 & 4: START RIDE ANIMATION & REAL-TIME TRACKING
  /// ──────────────────────────────────────────────────────────────────────────

  /// Start the ride start animation:
  /// 1. Camera zooms out to show full route (800ms flyTo)
  /// 2. Dropoff pin appears
  /// Simplified ride-start: draw remaining route + adaptive camera (no cinematic sequence).
  void _startStartRideAnimation() {
    if (_startRideAnimationDone) return;
    _startRideAnimationDone = true;
    _startRidePhase = 5; // skip to follow mode immediately

    _routeFadeTimer?.cancel();
    _routeOpacity = 1.0;

    if (_dropoffAnnot == null) {
      _dropoffPinAdded = false;
      _addDropoffPin();
    }

    // Remove the dimmed route — draw a bright one instead
    _removeDimmedRoute();

    // Draw the remaining route (driver → dropoff) immediately
    _routeDrawDone = false;
    _startAnimatedRouteDraw();

    // Fit camera to remaining route with adaptive zoom
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) _fitRouteBounds();
    });
  }

  /// Phase 1: Draw the route polyline progressively (animated draw effect)
  void _startRouteDrawAnimation() {
    if (_routePts.isEmpty) return;
    _addDropoffPin();
    _routeDrawDone = false;
    _startAnimatedRouteDraw();
  }

  /// Phase 2: Animate camera zoom out to show full route
  void _zoomOutCamToShowRoute() {
    _fitRouteBounds();
  }

  /// Phase 4: Animate camera zoom in and tilted to follow driver
  void _zoomInToCameraFollow() {
    _fitRouteBounds();
  }

  /// Start real-time camera tracking - follows driver every 2.5s.
  /// Skips during arrived phase — driver is stationary, camera should be stable.
  void _startCameraFollowTracking() {
    _cameraFollowTimer?.cancel();
    // Follow every 2.5s — longer interval prevents overlapping easeTo animations
    // which cause camera jitter when a new flyTo starts mid-animation.
    _cameraFollowTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      if (!mounted || !_shouldFollowDriver || _map == null) return;
      // During arrived phase the driver is at the pickup — no camera movement.
      if (_phase == _TrackPhase.arrived) return;
      if (_animPos.latitude == 0 && _animPos.longitude == 0) return;
      _followDriver(_animPos, _animBearing);
    });
  }

  /// Camera follows the route — always keeps driver + route ahead + destination
  /// visible so the rider never loses sight of where they're going.
  void _followDriver(LatLng position, double bearing) {
    if (_map == null || !mounted) return;
    // Skip if another camera animation is still running
    if (_cameraAnimating && DateTime.now().isBefore(_cameraAnimEnd)) return;
    if (position.latitude == 0 && position.longitude == 0) return;

    // Always use fitRouteBounds — it shows driver + route + destination
    // instead of centering on just the driver (which loses the route).
    _fitRouteBounds();
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

  /// Fetch driver photo directly from Firestore users collection when trip doc
  /// doesn't include it. Uses sql_{driverId} key matching the upload path.
  Future<void> _fetchDriverPhotoFromUserDoc(String driverId) async {
    if (!mounted) return;
    try {
      final docId = 'sql_$driverId';
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(docId)
          .get();
      if (!mounted) return;
      if (doc.exists) {
        final url = doc.data()?['photoUrl'] as String?;
        final normalized = _normalizeRemotePhotoUrl(url);
        if (normalized != null && normalized.isNotEmpty && (_driverPhotoUrl == null || _driverPhotoUrl!.isEmpty)) {
          _setState(() => _driverPhotoUrl = normalized);
        }
      }
    } catch (e) {
      debugPrint('[RiderTracking] Firestore driver photo fetch failed: $e');
    }
  }
}
