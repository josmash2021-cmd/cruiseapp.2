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
        // Firestore is a bonus channel — do NOT touch the 2s poll timer.
        // Slowing the poll when Firestore fires was causing missed "arrived"
        // events: the initial cached snapshot (old status) would downgrade the
        // poll to 8s, then the real arrived update took up to 8s to surface.
        _onTripStatusUpdate(data);
      },
      onError: (error) {
        debugPrint('[RiderTracking] Trip status listener error for $docId: $error');
        _pollFailCount++;
        if (mounted && _pollFailCount >= _maxPollFailsBeforeBanner && !_connectionLost) {
          _setState(() => _connectionLost = true);
        }
        // permission-denied → Firebase Auth session expired. Re-auth
        // and the listener will auto-reconnect on the next server push.
        if (error.toString().contains('permission-denied')) {
          FirebaseAuth.instance.signInAnonymously().ignore();
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

  /// Primary status channel — tries lightweight poll first, falls back to
  /// getActiveTrip if the new endpoint isn't deployed yet.
  Future<void> _pollBackendTripStatus() async {
    if (!mounted || _phase == _TrackPhase.completed) return;
    final tripId = widget.tripId;
    try {
      Map<String, dynamic>? data;

      if (tripId != null) {
        // Primary: fast raw-SQL endpoint
        data = await ApiService.pollTripStatus(tripId);
      }

      // Fallback: /trips/active — works even when tripId is null OR when
      // the primary poll endpoint fails/returns null for any reason.
      if (data == null && mounted) {
        final active = await ApiService.getActiveTrip();
        if (active != null) {
          final activeId = active['id'];
          if (tripId == null || activeId == tripId || activeId?.toString() == tripId.toString()) {
            data = {'status': active['status'], 'driver_id': active['driver_id']};
          }
        }
      }

      if (!mounted || data == null) {
        debugPrint('[RiderTracking] ⚠️ Poll got NO DATA (tripId=$tripId)');
        return;
      }
      final status = (data['status']?.toString() ?? '').trim().toLowerCase();
      if (status.isEmpty || status == 'not_found' || status == 'unknown') {
        debugPrint('[RiderTracking] ⚠️ Poll got empty/unknown status: "$status"');
        return;
      }

      // Log EVERY poll result so we can see exactly what's coming in.
      debugPrint('[RiderTracking] 📡 Poll → status="$status" (current phase=$_phase)');

      // Forward ANY actionable status — the handler has its own dedup/guards.
      // Intentionally broad: missing a transition is worse than a no-op update.
      const actionableStatuses = {
        'completed', 'cancelled', 'canceled',
        'arrived', 'driver_arrived', 'arrived_pickup', 'arrived_at_pickup',
        'in_trip', 'in_progress', 'rider_onboard', 'on_trip', 'trip_started',
      };
      if (actionableStatuses.contains(status)) {
        _onTripStatusUpdate({'status': status, 'driver_id': data['driver_id']});
      }
    } catch (e) {
      debugPrint('[RiderTracking] ❌ Poll error: $e');
      // H1 fix: surface connection issues to the rider. Previously this
      // silently swallowed auth/500/TLS errors and the "connection lost"
      // banner only fired from the Firestore path.
      _pollFailCount++;
      if (mounted &&
          _pollFailCount >= _maxPollFailsBeforeBanner &&
          !_connectionLost &&
          !NetworkService().isOnline) {
        _setState(() => _connectionLost = true);
      }
    }
  }

  /// Connect to backend poll + Firestore for trip status, RTDB for driver GPS.
  void _startRealTimeTracking() {
    final tripId = widget.tripId;
    final sqlDocId = tripId != null ? 'sql_$tripId' : null;
    final fallbackDocId = widget.firestoreTripId;

    // ── 1. PRIMARY: backend poll starts INSTANTLY — no auth dependency ──
    // Poll runs even when tripId is null — _pollBackendTripStatus uses /trips/active fallback.
    // Aggressive 1.5s interval — the extra traffic is trivial vs the cost of
    // a rider missing the "driver arrived" signal.
    _statusPollTimer?.cancel();
    _statusPollTimer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => _pollBackendTripStatus(),
    );
    unawaited(_pollBackendTripStatus()); // first poll fires now
    debugPrint('[RiderTracking] 🟢 Poll started for trip $tripId (every 1.5s)');

    // ── 2. BONUS: Firestore listener (instant when it works) ──
    // Firebase Auth + listener setup runs in parallel — never blocks the poll.
    _initFirebaseAndListeners(tripId, sqlDocId, fallbackDocId);

    // ── 3. RTDB driver GPS — start immediately if driverId known ──
    final did = widget.driverId;
    if (did != null && did.isNotEmpty && _rtdbDriverId != did) {
      _startRtdbDriverListener(did);
    }

    // Start chase camera follow timer
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

  /// Firebase Auth + Firestore listeners (bonus instant channel).
  /// Runs async in the background — never blocks the primary poll.
  void _initFirebaseAndListeners(int? tripId, String? sqlDocId, String? fallbackDocId) async {
    // Authenticate so Firestore security rules pass
    if (FirebaseAuth.instance.currentUser == null) {
      try { await FirebaseAuth.instance.signInAnonymously(); }
      catch (_) { debugPrint('[RiderTracking] Firebase anon auth failed — poll is primary'); }
    }
    if (!mounted) return;

    // Attach Firestore trip doc listener (delivers instant sub-second updates)
    if (sqlDocId != null) {
      _attachTripDocListener(sqlDocId, isFallbackDoc: false);
    }
    if (fallbackDocId != null &&
        fallbackDocId.isNotEmpty &&
        fallbackDocId != sqlDocId) {
      _attachTripDocListener(fallbackDocId, isFallbackDoc: true);
    } else {
      _fallbackTripStatusSub?.cancel();
      _fallbackTripStatusSub = null;
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

    debugPrint('[RiderTracking] ⚡ STATUS UPDATE: raw="$rawStatus" → normalized="$status" (phase=$_phase, confirmShown=$_confirmPickupShown, driverId=$did)');

    // ═══════════════════════════════════════════════════════════════════════
    //  COMPLETED — navigate to rating screen. Fires regardless of phase.
    // ═══════════════════════════════════════════════════════════════════════
    if (isCompletedStatus) {
      if (_phase == _TrackPhase.completed || _goingToRating) {
        debugPrint('[RiderTracking] ⏭️ completed already handled — skipping');
        return;
      }
      debugPrint('[RiderTracking] ✅ TRIP COMPLETED — navigating to rating in 1.5s');
      _goingToRating = true;
      unawaited(LocalDataService.clearActiveRide());
      _setState(() {
        _phase = _TrackPhase.completed;
        _showPickupOverlay = false;
      });
      _confirmPickupShown = false;
      _arrivedDotPulse.stop();
      _saveChatToInbox();
      // C7 fix: use a cancellable Timer so dispose() can kill the pending
      // navigation if the rider leaves the screen during the 1.5s delay.
      _ratingNavTimer?.cancel();
      _ratingNavTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) _goToRating();
      });
      return;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ARRIVED — show confirm pickup overlay. Fires regardless of phase
    //  as long as rider hasn't already confirmed pickup.
    // ═══════════════════════════════════════════════════════════════════════
    if (isArrivedStatus) {
      // Ignore if rider already confirmed (phase is onTrip or later) or trip done.
      if (_phase == _TrackPhase.onTrip ||
          _phase == _TrackPhase.nearDestination ||
          _phase == _TrackPhase.completed) {
        debugPrint('[RiderTracking] ⏭️ arrived ignored — phase=$_phase (already past pickup)');
        return;
      }
      debugPrint('[RiderTracking] 🎯 DRIVER ARRIVED — showing confirm pickup overlay');
      if (_phase != _TrackPhase.arrived) {
        _setState(() {
          _phase = _TrackPhase.arrived;
          _etaMinutes = 0;
          _distanceMiles = 0;
        });
        _saveRideState();
        if (!_arrivedDotPulse.isAnimating) _arrivedDotPulse.repeat(reverse: true);
        _handleDriverArrived();
      }
      // Always fire the overlay — guard inside _showRiderConfirmPickup handles dedup.
      _showRiderConfirmPickup();
      if (!_arrivedNotifSent) {
        _arrivedNotifSent = true;
        _sendRideNotification(
          'Your driver has arrived',
          '${widget.driverName.split(' ').first} is waiting at the pickup spot in a ${widget.vehicleColor} ${widget.vehicleModel}.',
        );
      }
      return;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  IN_TRIP — transition to onTrip phase. If overlay never fired, show
    //  it briefly as "auto-confirmed" before transitioning.
    // ═══════════════════════════════════════════════════════════════════════
    if (isInTripStatus) {
      if (_phase == _TrackPhase.onTrip ||
          _phase == _TrackPhase.nearDestination ||
          _phase == _TrackPhase.completed) {
        debugPrint('[RiderTracking] ⏭️ in_trip already handled — phase=$_phase');
        return;
      }
      debugPrint('[RiderTracking] 🚗 TRIP STARTED — transitioning to onTrip');
      if (_phase == _TrackPhase.arriving && !_confirmPickupShown) {
        // Driver skipped the arrived signal — flash the overlay briefly.
        _setState(() {
          _phase = _TrackPhase.arrived;
          _etaMinutes = 0;
          _distanceMiles = 0;
        });
        _handleDriverArrived();
        _showRiderConfirmPickup();
        Future.delayed(const Duration(milliseconds: 2500), () {
          if (!mounted) return;
          _transitionToOnTrip();
        });
        return;
      }
      _transitionToOnTrip();
      return;
    }

    if (isCancelledStatus) {
      // C3 fix: this handler can be invoked from a Firestore snapshot
      // callback AFTER the widget has been disposed. Bail out early to
      // avoid touching `context` on a dead State.
      if (!mounted || _phase == _TrackPhase.completed) return;

      // C2 fix: previously we ignored `cancelled` while in active phases
      // (onTrip / nearDestination) to defend against stale Firestore
      // snapshots.  The side effect was that LEGITIMATE cancels from
      // dispatch or the driver mid-ride were swallowed, leaving the rider
      // polling a dead trip forever. We now trust the status and use
      // `_cancelDialogShown` + `_goingToRating` as the only dedup guards.

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
        // C3 fix: capture the localised string BEFORE any async gap so we
        // never touch `context` from a stale closure.
        final String? operatorMessage = cancelledByDriver
            ? null
            : S.of(context).tripCancelledByOperator;
        _cancelDialogShown = true;
        _showDriverCancelledDialog(message: operatorMessage);
      }
    }
  }

  /// Transition to the onTrip phase — shared by normal flow and catch-up flow.
  void _transitionToOnTrip() {
    if (!mounted || _phase == _TrackPhase.onTrip || _phase == _TrackPhase.nearDestination) return;
    // Swap to trip route
    if (_tripRoutePts.isNotEmpty) {
      _routePts = _tripRoutePts;
      _buildSegDist();
    }
    _traveledM = 0;
    _tgtTraveledM = 0;
    _velocityMps = 0;
    _approachRouteFetched = false;
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
    _shouldFollowDriver = true;
    _startCameraFollowTracking();
    _saveRideState();
    _tripStartedTimer?.cancel();
    _tripStartedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) _setState(() => _tripJustStarted = false);
    });
    _arrivedDotPulse.stop();
    _popOutPickupPin();
    if (_showPickupOverlay) {
      _confirmPickupShown = false;
      _setState(() => _showPickupOverlay = false);
    }
    _startRideAnimationDone = false;
    _startStartRideAnimation();
  }

  /// Show the rider confirmation pickup overlay when driver has arrived.
  /// Uses inline Stack overlay (not Navigator.push) so it always appears,
  /// even during route transitions or when the Navigator is busy.
  void _showRiderConfirmPickup() {
    if (!mounted || _confirmPickupShown) return;
    _confirmPickupShown = true;
    _setState(() => _showPickupOverlay = true);
    // Slide overlay up from the bottom
    _pickupOverlayCtrl.forward(from: 0);
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
      // Throttle: max 15 updates/sec — gives _interpolate more GPS data to
      // blend, matching the Google-Maps glide feel of the driver side. The
      // interp ticker runs at vsync (~60fps) so this is just a floor on how
      // often we re-seed the target, not how often we redraw.
      final now = DateTime.now();
      if (lastRtdbUpdate != null &&
          now.difference(lastRtdbUpdate!).inMilliseconds < 66) {
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
        // C6 fix: defensive check — don't re-create the poll timer if the
        // trip is already completed (a late RTDB event could otherwise
        // restart polling on a dead trip forever).
        if (mounted && _phase != _TrackPhase.completed) {
          _statusPollTimer = Timer.periodic(const Duration(seconds: 8), (_) {
            _pollBackendTripStatus();
          });
        }
      }
      if (_connectionLost) _setState(() => _connectionLost = false);
      _onRealDriverLocation(LatLng(lat, lng), bearing: bearing, speed: speed);
    }, onError: (e) {
      debugPrint('[RiderTracking] RTDB stream error: $e');
      _pollFailCount++;
      _rtdbFailCount++;
      // permission-denied → session expired. Re-auth so the reconnect
      // attempt (below) succeeds with a fresh token.
      if (e.toString().contains('permission-denied')) {
        FirebaseAuth.instance.signInAnonymously().ignore();
      }
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
        // C6 fix: defensive check — same reasoning as the success path above.
        if (mounted && _phase != _TrackPhase.completed) {
          _statusPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
            _pollBackendTripStatus();
          });
        }
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

    // Suppress notifications and overlays that already fired in the previous session.
    // Without this, reopening the app re-sends "driver has arrived" notifications
    // and re-shows the confirm pickup overlay.
    if (_phase == _TrackPhase.arrived || _phase == _TrackPhase.onTrip || _phase == _TrackPhase.nearDestination) {
      _greetingSent = true;
      _arrivedNotifSent = true;
    }
    if (_phase == _TrackPhase.onTrip || _phase == _TrackPhase.nearDestination) {
      _confirmPickupShown = true;
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
    final isBackendCompleted = s == 'completed';
    if (isBackendCompleted) {
      // Trip finished while app was closed — go straight to rating
      _phase = _TrackPhase.completed;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _goToRating();
      });
      return; // skip rest of persistence restore
    }
    if (isBackendInTrip && (_phase == _TrackPhase.arriving || _phase == _TrackPhase.arrived)) {
      _phase = _TrackPhase.onTrip;
      _greetingSent = true;
      _arrivedNotifSent = true;
      _confirmPickupShown = true;
    } else if (isBackendArrived && _phase == _TrackPhase.arriving) {
      _phase = _TrackPhase.arrived;
      _greetingSent = true;
      _arrivedNotifSent = true;
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
        if (mounted) {
          _handleDriverArrived();
          _showRiderConfirmPickup();
        }
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
    // 1.0 s lookahead (was 0.6 s) — gives the car enough runway to glide
    // through 1-second GPS gaps without any visible deceleration.
    final predicted = _tgtTraveledM + _velocityMps * 1.0;
    final effectiveTarget = math.min(predicted, _segDist.last);
    final diff = effectiveTarget - _traveledM;

    // Primary: advance at measured driver speed (m/s × dt).
    // This distributes movement EVENLY across ALL frames between GPS updates
    // instead of proportional catch-up which reaches target in 200ms then stalls.
    final velStep = _velocityMps * dt;
    // Proportional correction (8%/frame at 60fps) — strong enough to
    // absorb GPS jumps within ~0.5s, weak enough to stay invisible
    // during smooth driving.
    final corrStep = diff * tf(0.08);
    // Use whichever produces more forward movement — velocity dominates while
    // driving, correction dominates when stopped.
    if (diff > 0.05) {
      final step2 = math.max(velStep, corrStep).clamp(0.0, 12.0);
      _traveledM = math.min(_traveledM + step2, effectiveTarget);
    } else if (diff.abs() <= 0.05) {
      _traveledM = _tgtTraveledM;
    }
    // Velocity decay: retain ~99.7% per second — sustains glide for 8+ sec
    // GPS gaps so the car NEVER stalls even in tunnels or GPS shadows.
    // Real driver speed is refreshed every ~1-2s from RTDB, so barely decays.
    _velocityMps *= math.pow(0.997, dt);

    final (pos, brg) = _posAtDistUltraSmooth(_traveledM);

    // ── Bearing: time-based rotation for smooth car nose direction ──
    // 0.35 per frame (was 0.50) — slower rotation gives a cinematic
    // feel on curves instead of snappy heading changes.
    double db = brg - _animBearing;
    if (db > 180) db -= 360;
    if (db < -180) db += 360;
    final brgFactor = tf(0.35);
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
    // Follow every 800ms — short enough to feel fluid, long enough to avoid
    // overlapping easeTo animations (600ms animation + 200ms settle).
    _cameraFollowTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
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
