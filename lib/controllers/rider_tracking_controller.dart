part of '../screens/rider_tracking_screen.dart';

// ════════════════════════════════════════════════════════════
//  CONTROLLER — Firebase listeners, trip phases, persistence
// ════════════════════════════════════════════════════════════

extension _RiderTrackingController on _RiderTrackingScreenState {

  /// Whether the "connection lost" banner would be telling the truth.
  ///
  /// Requires BOTH enough failures AND real silence from every channel.
  /// The failure counter alone is shared by four independent channels and
  /// is reset by whichever one happens to succeed, so on its own it fires
  /// for a single broken channel while the screen is updating fine — which
  /// is exactly the phantom "Connection lost — reconnecting..." the rider
  /// sees with a full signal bar.
  bool get _shouldFlagConnectionLost {
    if (!mounted || _connectionLost) return false;
    if (_pollFailCount < _maxPollFailsBeforeBanner) return false;
    final last = _lastAnyDataAt;
    // Nothing has arrived yet — the screen just opened. Don't accuse.
    if (last == null) return false;
    return DateTime.now().difference(last).inMilliseconds > _kNoDataBannerMs;
  }

  /// Record that a channel delivered data: clears the failure counter and
  /// refreshes the silence clock the banner is gated on.
  void _markChannelAlive() {
    _pollFailCount = 0;
    _lastAnyDataAt = DateTime.now();
    if (_connectionLost) _setState(() => _connectionLost = false);
  }

  void _attachTripDocListener(
    String docId, {
    required bool isFallbackDoc,
  }) {
    final listener = TripFirestoreService.watchTrip(docId).listen(
      (data) {
        if (!mounted) return;
        if (data == null) {
          // An absent FALLBACK doc is not a failure — it is an optional
          // document that was simply never created, and it reports null on
          // every single snapshot. Counting those walked the failure
          // counter to the banner threshold on a perfectly healthy trip.
          if (isFallbackDoc) return;
          _pollFailCount++;
          debugPrint('[RiderTracking] Trip data null for $docId ($_pollFailCount/$_maxPollFailsBeforeBanner)');
          if (_shouldFlagConnectionLost) {
            _setState(() => _connectionLost = true);
          }
          return;
        }
        _markChannelAlive();
        // Mark Firestore as recently alive so the very next 1.5s poll tick
        // can skip the HTTP GET (data already delivered here). We do NOT
        // slow the timer interval — a stale cached snapshot could make us
        // miss a live "arrived" event if we downgrade and then Firestore
        // goes quiet. The skip is tight (700 ms window) so the poll still
        // fires when Firestore stalls.
        _lastFirestoreEventAt = DateTime.now();
        if ((data['status']?.toString() ?? '').trim().isNotEmpty) {
          _lastLiveStatusAt = _lastFirestoreEventAt;
        }
        _onTripStatusUpdate(data);
      },
      onError: (error) {
        debugPrint('[RiderTracking] Trip status listener error for $docId: $error');
        _pollFailCount++;
        if (_shouldFlagConnectionLost) {
          _setState(() => _connectionLost = true);
        }
        // permission-denied → the anonymous session is dead. Recycle it
        // properly: plain signInAnonymously() returns the SAME broken user
        // when one is already signed in, so the old recovery never
        // recovered anything. See FirebaseAuthRecovery.
        final isPermDenied = error is FirebaseException && error.code == 'permission-denied';
        if (isPermDenied || error.toString().contains('permission-denied')) {
          FirebaseAuthRecovery.refreshAnonymousSession().ignore();
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
    // Skip this tick if Firestore already delivered the same data
    // within the last 700 ms — avoids redundant HTTP GETs during the
    // 90 % of the trip where Firestore is healthy. If Firestore stalls
    // (>700 ms) we fall through and do the poll normally, so no event
    // can ever be missed.
    if (_lastFirestoreEventAt != null &&
        DateTime.now().difference(_lastFirestoreEventAt!).inMilliseconds < 700) {
      return;
    }
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
      // 2026-04-27 fix: include 'accepted' / 'driver_en_route' so the RTDB
      // listener bootstrap inside _onTripStatusUpdate fires for cold-start
      // riders who land on the tracking screen with widget.driverId == null.
      // Without those entries the rider could see the route but never the
      // moving car, because the listener was never started.
      const actionableStatuses = {
        'accepted', 'driver_en_route', 'driver_enroute', 'enroute',
        'completed', 'cancelled', 'canceled',
        'arrived', 'driver_arrived', 'arrived_pickup', 'arrived_at_pickup',
        'in_trip', 'in_progress', 'rider_onboard', 'on_trip', 'trip_started',
      };
      // Also forward unconditionally if we have a driver_id and our RTDB
      // listener isn't running yet — guarantees the car appears even if a
      // status string we haven't seen before sneaks in from a future
      // backend change.
      final driverId = data['driver_id']?.toString() ?? '';
      final needsBootstrap = driverId.isNotEmpty &&
          driverId != '0' &&
          (_rtdbDriverId == null || _rtdbDriverId != driverId);
      if (actionableStatuses.contains(status) || needsBootstrap) {
        _onTripStatusUpdate({'status': status, 'driver_id': data['driver_id']});
      }
    } catch (e) {
      debugPrint('[RiderTracking] ❌ Poll error: $e');
      // H1 fix: surface connection issues to the rider. Previously this
      // silently swallowed auth/500/TLS errors and the "connection lost"
      // banner only fired from the Firestore path.
      _pollFailCount++;
      if (_shouldFlagConnectionLost) {
        _setState(() => _connectionLost = true);
      }
    }
  }

  /// Connect to SSE (primary) + Socket.io (GPS) + backend poll (fallback).
  /// Firestore is now tertiary fallback only.
  void _startRealTimeTracking() {
    final tripId = widget.tripId;
    final sqlDocId = tripId != null ? 'sql_$tripId' : null;
    final fallbackDocId = widget.firestoreTripId;

    // ── 0. PRIMARY: SSE trip status stream (<100ms latency) ──
    if (tripId != null) {
      _startSseTripTracking(tripId);
    }

    // ── 1. PRIMARY GPS: Socket.io real-time channel ──
    if (FeatureFlags.useSocketIO && tripId != null) {
      _startSocketIOTracking(tripId);
    }

    // ── 2. BACKUP: backend poll — only when SSE is down ──
    _statusPollTimer?.cancel();
    _startAdaptivePolling();

    // ── 3. FALLBACK: Firestore listener (only if SSE fails) ──
    // Delayed start — SSE handles 99% of updates, Firestore is safety net.
    _initFirebaseAndListeners(tripId, sqlDocId, fallbackDocId);

    // ── 3. RTDB driver GPS — the fallback, armed by silence ──
    //
    // This used to defer to Socket.io whenever the socket was *connected*,
    // on the reasoning that RTDB would then be redundant bandwidth. Connected
    // is not delivering: a rider holding a perfectly healthy socket that is
    // simply not being sent this driver's GPS got no position at all, and the
    // condition guarding the fallback (`!SocketService.isConnected`) was
    // false the entire time, so it never armed. The car sat frozen on the map
    // for the whole ride and nothing in the app considered that a fault.
    //
    // Keep the deferral — the socket really is the cheaper channel — but arm
    // it on the only evidence that matters: whether any GPS has arrived.
    final did = widget.driverId;
    if (did != null && did.isNotEmpty && _rtdbDriverId != did) {
      if (!SocketService.isConnected) {
        _startRtdbDriverListener(did);
      } else {
        debugPrint('[RiderTracking] Socket.io connected — deferring RTDB start');
        _gpsFallbackTimer?.cancel();
        _gpsFallbackTimer = Timer(const Duration(seconds: 8), () {
          if (!mounted || _phase == _TrackPhase.completed) return;
          if (_lastDriverGpsAt == null && _rtdbDriverId == null) {
            debugPrint('[RiderTracking] no driver GPS after 8s — starting RTDB fallback');
            _startRtdbDriverListener(did);
          }
        });
      }
    }
    _startDriverGpsWatchdog();

    // Start chase camera follow timer
    _startCameraFollowTracking();

    // Periodically persist ride state so app resumption restores correct position
    _rideSaveTimer?.cancel();
    _rideSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && _phase != _TrackPhase.completed) _saveRideState();
    });

    // Fallback: if no GPS arrives within 5s during arriving phase,
    // fetch approach route using the driver's last known position.
    if (_phase == _TrackPhase.arriving && !_approachRouteFetched) {
      _approachRouteTimer?.cancel();
      _approachRouteTimer = Timer(const Duration(seconds: 5), () {
        if (!mounted || _phase != _TrackPhase.arriving) return;
        if (_approachRouteFetched || _approachRouteFetching || _approachRouteFailed) return;
        // Use persisted driver position if available
        if (_driverPos.latitude != 0 && _driverPos.longitude != 0) {
          debugPrint('[RiderTracking] No GPS in 5s — using persisted driver pos for approach route');
          _onRealDriverLocation(_driverPos);
        } else {
          // Last resort: fetch driver position from backend
          _fetchDriverPositionFallback();
        }
      });
    }
  }

  /// Adaptive polling: slow when Socket.io is healthy, faster when it's down.
  void _startAdaptivePolling() {
    _statusPollTimer?.cancel();
    _statusPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted || _phase == _TrackPhase.completed) {
        _statusPollTimer?.cancel();
        return;
      }
      // Skip only what would be genuinely redundant: a status that a live
      // channel already delivered inside this same tick window.
      //
      // The old condition was `Socket.io connected && Firestore spoke
      // recently`, which is a statement about plumbing, not about data. See
      // [_lastLiveStatusAt] — a rider can hold a healthy socket to a worker
      // that will never be handed the driver's status change, and this poll
      // is the only channel that always sees the database itself. Skipping
      // it on a liveness proxy is how a swipe on the driver's phone took
      // several seconds to reach the passenger's screen.
      final justDelivered = _lastLiveStatusAt != null &&
          DateTime.now().difference(_lastLiveStatusAt!).inMilliseconds < 1500;
      if (justDelivered) return;
      _pollBackendTripStatus();
    });
    unawaited(_pollBackendTripStatus()); // first poll fires immediately
    debugPrint('[RiderTracking] 🟢 Adaptive poll started (every 2s, skips when Socket.io+Firestore healthy)');
  }

  /// Start SSE trip status stream — PRIMARY channel for instant updates (<100ms).
  /// Replaces Firestore as the main real-time channel.
  void _startSseTripTracking(int tripId) {
    _sseTripSub?.cancel();
    _sseActive = false;

    _sseTripSub = ApiService.streamTripStatus(tripId).listen(
      (data) {
        if (!mounted || _phase == _TrackPhase.completed) return;
        _sseActive = true;
        _markChannelAlive();

        // Log latency if timestamp present
        final ts = data['ts'] as num?;
        if (ts != null) {
          final latency = (DateTime.now().millisecondsSinceEpoch - (ts * 1000)).round();
          debugPrint('[SSE] Trip update latency: ${latency}ms');
        }

        debugPrint('[SSE] Trip status update: ${data['status']}');
        if ((data['status']?.toString() ?? '').trim().isNotEmpty) {
          _lastLiveStatusAt = DateTime.now();
        }
        _onTripStatusUpdate(data);
      },
      onError: (e) {
        debugPrint('[SSE] Trip stream error: $e');
        _sseActive = false;
      },
      onDone: () {
        debugPrint('[SSE] Trip stream closed — will reconnect');
        _sseActive = false;
      },
    );

    debugPrint('[RiderTracking] 📡 SSE trip tracking started for trip $tripId');
  }

  /// Start Socket.io listeners for trip status and driver GPS.
  void _startSocketIOTracking(int tripId) async {
    // FIX: await init() BEFORE subscribing so the socket is actually ready.
    // Previously subscriptions were created immediately while init() ran in
    // the background, causing events to be lost if the socket wasn't already
    // connected.
    await SocketService.init();
    if (!mounted) return;
    // Join trip room
    SocketService.joinTrip(tripId);

    // Listen for driver location updates
    _socketLocationSub?.cancel();
    _socketLocationSub = SocketService.driverLocationStream.listen((data) {
      if (!mounted || _phase == _TrackPhase.completed) return;

      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) return;

      final bearing = (data['heading'] as num?)?.toDouble();
      final speed = (data['speed'] as num?)?.toDouble();

      // Log latency
      final timestamp = data['timestamp'] as int?;
      if (timestamp != null) {
        final latency = DateTime.now().millisecondsSinceEpoch - timestamp;
        debugPrint('[Socket.io] GPS latency: ${latency}ms');
      }

      _markChannelAlive();
      _onRealDriverLocation(LatLng(lat, lng), bearing: bearing, speed: speed,
          timestampMs: _fixTimestampMs(data['timestamp']));
    });

    // Listen for trip status updates
    _socketStatusSub?.cancel();
    _socketStatusSub = SocketService.tripStatusStream.listen((data) {
      if (!mounted || _phase == _TrackPhase.completed) return;

      final status = data['status']?.toString().toLowerCase().trim();
      if (status == null || status.isEmpty) return;

      // Log latency
      final timestamp = data['timestamp'] as int?;
      if (timestamp != null) {
        final latency = DateTime.now().millisecondsSinceEpoch - timestamp;
        debugPrint('[Socket.io] Status latency: ${latency}ms');
      }

      debugPrint('[Socket.io] Trip status update: $status');
      _lastLiveStatusAt = DateTime.now();
      _onTripStatusUpdate({'status': status, 'driver_id': data['driver_id']});
    });

    // Monitor Socket.io health — start RTDB fallback if connection drops
    _socketHealthSub?.cancel();
    _socketHealthSub = SocketService.connectionHealthStream.listen((isHealthy) {
      if (!mounted || _phase == _TrackPhase.completed) return;
      final did = widget.driverId;
      if (!isHealthy && did != null && did.isNotEmpty && _rtdbDriverId == null) {
        debugPrint('[RiderTracking] Socket.io disconnected — starting RTDB fallback');
        _startRtdbDriverListener(did);
      }
    });

    debugPrint('[RiderTracking] 🔌 Socket.io tracking started for trip $tripId');
  }

  /// Firebase Auth + Firestore listeners (bonus instant channel).
  /// Runs async in the background — never blocks the primary poll.
  void _initFirebaseAndListeners(int? tripId, String? sqlDocId, String? fallbackDocId) async {
    // Authenticate so Firestore security rules pass
    if (FirebaseAuth.instance.currentUser == null) {
      try { await FirebaseAuthRecovery.ensureSignedIn(); }
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
        // The backend's cached position lags the live channels by design —
        // it is only written when the driver's app reports in. Feeding it
        // over a fix that arrived seconds ago drags the car backwards, the
        // "jump" riders see right after the live feed hiccups and recovers.
        final lastFixMs = _lastAcceptedFixAt;
        if (lastFixMs != null &&
            DateTime.now().millisecondsSinceEpoch - lastFixMs < 12000) {
          debugPrint('[RiderTracking] Fallback skipped — live fix is fresher');
          return;
        }
        debugPrint('[RiderTracking] Fallback: got driver pos from backend ($driverLat, $driverLng)');
        if (mounted) _onRealDriverLocation(LatLng(driverLat, driverLng));
      }
    } catch (e) {
      debugPrint('[RiderTracking] Fallback driver pos fetch failed: $e');
    }
  }

  /// Watch for the driver's position going silent and re-arm the fallback.
  ///
  /// The two live GPS channels fail differently and neither reports it: a
  /// Socket.io room can stay joined while nothing is routed to it, and an
  /// RTDB listener can survive an auth expiry as a subscription that never
  /// fires again. In both cases every health flag the app owns keeps saying
  /// "fine" while the passenger watches a car that has stopped moving.
  /// Silence is the only symptom, so silence is what this watches.
  void _startDriverGpsWatchdog() {
    _driverGpsWatchdog?.cancel();
    _driverGpsWatchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || _phase == _TrackPhase.completed) {
        _driverGpsWatchdog?.cancel();
        return;
      }
      final did = widget.driverId ?? _rtdbDriverId;
      if (did == null || did.isEmpty) return;

      final last = _lastDriverGpsAt;
      // 15 s. Long enough that a driver stopped at a light — the streams use
      // a distance filter and legitimately emit nothing — is not mistaken
      // for a dead channel.
      final silent = last == null ||
          DateTime.now().difference(last).inSeconds > 15;
      if (!silent) return;

      // Bring RTDB up, or rebuild it if it is the one that went quiet. This
      // is deliberately cheap to repeat: _startRtdbDriverListener cancels
      // its previous subscription first.
      debugPrint('[RiderTracking] driver GPS silent — re-arming RTDB feed');
      _startRtdbDriverListener(did);

      // And ask the backend directly. RTDB only carries what the driver's
      // app publishes; if that is what died, the server's last known
      // position is the only thing left that can move the car.
      if (_phase != _TrackPhase.arrived) _fetchDriverPositionFallback();
    });
  }

  /// Normalise a fix timestamp from any channel to ms epoch.
  /// Socket.io sends ms; RTDB writes may carry seconds.
  double? _fixTimestampMs(dynamic ts) {
    if (ts is! num) return null;
    final v = ts.toDouble();
    if (!v.isFinite || v <= 0) return null;
    return v < 1e12 ? v * 1000 : v; // seconds → ms
  }

  /// Process real-time driver location from RTDB.
  ///
  /// [timestampMs] is the fix's own timestamp (ms epoch) when the channel
  /// carries one. Fixes older than the last accepted one are dropped, so a
  /// stale retry or a late re-delivery can never pull the car backwards.
  /// When no timestamp travels, arrival order is the only clock we have;
  /// the same fix fanning out over socket AND RTDB is deduped by position.
  void _onRealDriverLocation(LatLng ll, {double? bearing, double? speed, double? timestampMs}) {
    if (ll.latitude == 0 && ll.longitude == 0) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch.toDouble();
    if (timestampMs != null) {
      final last = _lastAcceptedFixAt;
      if (last != null && timestampMs < last) {
        debugPrint('[RiderTracking] Dropping stale fix (${(last - timestampMs).round()}ms old)');
        return;
      }
    } else {
      // No payload timestamp: dedupe the same fix arriving through a second
      // channel (socket + RTDB both carry the driver's last write).
      final lastAt = _lastAcceptedFixAt;
      final lastLat = _lastAcceptedFixLat;
      final lastLng = _lastAcceptedFixLng;
      if (lastAt != null &&
          lastLat != null &&
          lastLng != null &&
          nowMs - lastAt < 1500 &&
          (ll.latitude - lastLat).abs() < 1e-6 &&
          (ll.longitude - lastLng).abs() < 1e-6) {
        return; // same fix, other channel
      }
    }
    _lastAcceptedFixAt = timestampMs ?? nowMs;
    _lastAcceptedFixLat = ll.latitude;
    _lastAcceptedFixLng = ll.longitude;
    _lastDriverGpsAt = DateTime.now();
    // Validate bearing — NaN/Infinity would break rotation interpolation
    if (bearing != null && (bearing.isNaN || bearing.isInfinite)) bearing = null;
    if (speed != null && (speed.isNaN || speed.isInfinite || speed < 0)) speed = null;
    // Feed the motion engine first — every packet from every channel lands
    // here, and the engine decides what is movement and what is parked-car
    // GPS wander. No accuracy travels on the socket; 8 m is a fair street-
    // level standstill radius for phone GPS.
    _carMotion.setTarget(ll.latitude, ll.longitude,
        bearing: bearing, accuracyM: 8.0);
    // 2026-04-27 diagnostic: log every incoming GPS so we can see in
    // device logs whether the rider is even RECEIVING the driver
    // updates. If this never prints while the car sits frozen, the
    // problem is upstream (RTDB rules / driver app GPS / listener).
    // If it DOES print but the car still doesn't move, the bug is in
    // the interp pipeline below.
    // Debug builds only: this runs for every packet from BOTH live
    // channels and formats a dozen doubles each time — pure overhead on
    // the same UI isolate that is animating the car.
    if (kDebugMode) {
      debugPrint(
      '[RiderTracking] GPS in: lat=${ll.latitude.toStringAsFixed(5)} '
      'lng=${ll.longitude.toStringAsFixed(5)} '
      'speed=${speed?.toStringAsFixed(1) ?? "n/a"} '
      'phase=$_phase '
      'segDist=${_segDist.length} routePts=${_routePts.length} '
      'traveledM=${_traveledM.toStringAsFixed(1)} '
      'tgtTraveledM=${_tgtTraveledM.toStringAsFixed(1)} '
      'velMps=${_velocityMps.toStringAsFixed(2)} '
      'animPos=(${_animPos.latitude.toStringAsFixed(5)},${_animPos.longitude.toStringAsFixed(5)}) '
      'tickerActive=${_interpTicker?.isActive ?? false}',
      );
    }
    // Always wake up the ticker on new GPS data — restarts if idle or stopped.
    _interpIdle = false;
    if (_interpTicker != null && !_interpTicker!.isActive) {
      _interpTicker!.start();
    }

    // Start heartbeat timer on first GPS — forces car recreation if it never appeared.
    // This catches edge cases where the annotation was lost (style reload, map rebuild, etc.)
    if (_carFirstGpsTime == null) {
      _carFirstGpsTime = DateTime.now();
      _carHeartbeatTimer?.cancel();
      _carHeartbeatTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (!mounted) {
          _carHeartbeatTimer?.cancel();
          return;
        }
        // If car annotation is missing but we have GPS and icon, force recreate
        // Guard: don't recreate if one is already in progress
        final hasValidPos = (_animPos.latitude != 0 || _animPos.longitude != 0) ||
            (_directTargetPos != null && _directTargetPos!.latitude != 0 && _directTargetPos!.longitude != 0);
        if (_carAnnot == null && !_carAnnotCreating && _carPngBytes != null && hasValidPos) {
          debugPrint('[CarIcon] HEARTBEAT: car missing, forcing recreation');
          _updateCarSmooth();
        }
      });
    }

    // FORCE immediate car update on first GPS — don't wait for next ticker frame.
    // This ensures the car appears instantly when the first driver location arrives.
    _updateCarSmooth();

    // Uber-style: fetch approach route (driver→pickup) on first GPS during arriving
    if (_phase == _TrackPhase.arriving &&
        !_approachRouteFetched &&
        !_approachRouteFetching &&
        !_approachRouteFailed) {
      unawaited(_fetchApproachRoute(ll));
    }

    // During arriving phase BEFORE approach route loads: the route polyline
    // is the TRIP route (pickup→dropoff), not the approach route (driver→pickup).
    // Projecting the driver's GPS onto the trip route gives a completely wrong
    // position (e.g. driver 2 miles away gets projected onto the trip route).
    // Use raw GPS directly until the approach route is ready.
    // NOTE: Even AFTER approach route loads, if the driver is still far from
    // the route, keep using raw GPS so the car doesn't snap to a wrong position.
    final isArrivingWithoutApproach = _phase == _TrackPhase.arriving && !_approachRouteFetched;

    // Always try to snap GPS onto the route polyline.
    // Only fall back to raw GPS lerp when we truly have no route OR when
    // the driver is too far from the route (arriving phase, driver still far away).
    final driverFarFromRoute = _phase == _TrackPhase.arriving && _approachRouteFetched &&
        _segDist.isNotEmpty && _routePts.length >= 2;
    bool shouldProjectOntoRoute = !isArrivingWithoutApproach && _segDist.isNotEmpty && _routePts.length >= 2;
    if (shouldProjectOntoRoute) {
      final projectedM = _projectOntoRoute(ll);
      // Accept projection when close enough to route (< 150m lateral)
      final snappedPos = _posAtDistUltraSmooth(projectedM.clamp(0.0, _segDist.last)).$1;
      final lateralM = _hav(ll, snappedPos) * 1609.34;
      // Off-route bookkeeping + auto-reroute trigger. Runs on EVERY fix with
      // a route on screen, not just past the 150 m visual fallback — the
      // 45 m threshold with hysteresis lives in _updateOffRouteState.
      _updateOffRouteState(lateralM, ll);
      if (lateralM < 150) {
        final clampedM = projectedM.clamp(0.0, _segDist.last);
        // 2026-04-27 FIX: was `clampedM >= _traveledM - 5` which silently
        // dropped every GPS update where the driver appeared to retreat
        // even slightly (GPS jitter, snap projecting backward, brief
        // stop). Result: _tgtTraveledM never updated, _velocityMps stayed
        // 0, the car pin froze on screen even though the driver was
        // actually moving. New rule: ALWAYS accept the projection;
        // never let the target go backward, just clamp to current.
        final newTarget = math.max(clampedM, _traveledM);
        // Use real driver speed from RTDB when available (most accurate).
        // Fall back to calculated velocity from GPS deltas.
        final now = DateTime.now();
        final dtSec = now.difference(_lastGpsTime).inMilliseconds / 1000.0;
        if (speed != null && speed > 0.1) {
          // Real driver speed — smooth with 30/70 blend for stability.
          // Always honored even if delta is 0 (GPS jitter on a moving
          // driver) so the ticker has velocity to advance with.
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
        // Anti-stall: if we got several GPS updates in a row but
        // velocity is still ~0 AND the target IS ahead of where we are
        // visually, kick in a minimum 4 m/s (~9 mph, slow city pace) so
        // the ticker has something to advance with. The proportional
        // correction (corrStep, 8%/frame) will tune it to the real
        // pace within ~0.5s.
        if (_velocityMps < 0.5 && newTarget - _traveledM > 3) {
          _velocityMps = 4.0;
        }
        _lastGpsTime = now;
        _tgtTraveledM = newTarget;
        _directTargetPos = null;
        _directTargetBearing = null;
      } else {
        // Too far from route — use raw GPS lerp as fallback. The reroute
        // itself was already considered by _updateOffRouteState above.
        _directTargetPos = ll;
        _directTargetBearing = bearing;
      }
    } else {
      // No route available OR arriving without approach route yet OR driver far from route:
      // use raw GPS lerp so the car appears at the driver's real position.
      _directTargetPos = ll;
      _directTargetBearing = bearing;
    }

    // Ensure car is visible immediately — force update even before ticker runs
    if (_carAnnot == null && _carPngBytes != null && _carAnnotMgr != null && !_carAnnotCreating) {
      _updateCarSmooth();
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
        _etaMinutes = (remainM / _velocityMps / 60.0).ceil().clamp(1, 999);
      } else if (_routeDurationSec != null && _routeDurationSec! > 0 && _segDist.isNotEmpty && _segDist.last > 0) {
        // Scale route duration by fraction of distance remaining
        final fraction = ((_segDist.last - _traveledM) / _segDist.last).clamp(0.0, 1.0);
        _etaMinutes = (_routeDurationSec! * fraction / 60.0).ceil().clamp(1, 999);
      } else {
        _etaMinutes = (_distanceMiles / 0.4).ceil().clamp(1, 999);
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
        _etaMinutes = (remainM / _velocityMps / 60.0).ceil().clamp(1, 999);
      } else if (_routeDurationSec != null && _routeDurationSec! > 0 && _segDist.isNotEmpty && _segDist.last > 0) {
        final fraction = ((_segDist.last - _traveledM) / _segDist.last).clamp(0.0, 1.0);
        _etaMinutes = (_routeDurationSec! * fraction / 60.0).ceil().clamp(1, 999);
      } else {
        // Fallback: 0.4 mi/min ≈ 24 mph average urban
        _etaMinutes = (_distanceMiles / 0.4).ceil().clamp(1, 999);
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

  /// Off-route bookkeeping + auto-reroute trigger.
  ///
  /// [lateralM] is the driver's perpendicular distance to the active route
  /// polyline in meters. Beyond [_kOffRouteMeters], sustained for
  /// [_kOffRouteSustainMs], a reroute fires; the state re-arms below
  /// [_kBackOnRouteMeters] so GPS noise around the threshold cannot flap it,
  /// and [_kRerouteCooldownSec] keeps a long detour from hammering the API.
  void _updateOffRouteState(double lateralM, LatLng ll) {
    if (lateralM < _kBackOnRouteMeters) {
      _offRouteSince = null;
      return;
    }
    if (lateralM <= _kOffRouteMeters) return; // hysteresis band: keep state
    // Only phases whose on-screen route is the driver's own path reroute:
    // the approach leg once its road route is on screen (driver → pickup),
    // and the trip leg (car → dropoff). arrived/completed never do.
    final canReroute = _phase == _TrackPhase.onTrip ||
        _phase == _TrackPhase.nearDestination ||
        (_phase == _TrackPhase.arriving && _approachRouteFetched);
    if (!canReroute || _rerouteInProgress) return;
    final now = DateTime.now();
    _offRouteSince ??= now;
    if (now.difference(_offRouteSince!).inMilliseconds < _kOffRouteSustainMs) {
      return;
    }
    final last = _lastRerouteAt;
    if (last != null &&
        now.difference(last).inSeconds < _kRerouteCooldownSec) {
      return;
    }
    // Re-arm the sustain clock for the NEXT deviation. Without this, a
    // driver who never dips under 30 m of the new line (failed fetch, GPS
    // bias on a parallel road) keeps a stale timestamp and a single noisy
    // fix would fire the next reroute the moment the cooldown lapses.
    _offRouteSince = null;
    unawaited(_rerouteFromCurrentPos(ll));
  }

  /// Fetch a new route from the driver's current position to the active
  /// destination — pickup while the driver is still coming, dropoff once
  /// the rider is aboard — and splice it into the line on screen.
  Future<void> _rerouteFromCurrentPos(LatLng driverPos) async {
    _rerouteInProgress = true;
    _lastRerouteAt = DateTime.now();
    final toPickup = _phase == _TrackPhase.arriving;
    final dest = toPickup ? widget.pickupLatLng : widget.dropoffLatLng;
    debugPrint('[RiderTracking] Rerouting from driver pos '
        '(${driverPos.latitude}, ${driverPos.longitude}) → '
        '${toPickup ? "pickup" : "dropoff"}');
    try {
      final ds = DirectionsService(ApiKeys.webServices);
      final result = await ds.getRoute(
        origin: driverPos,
        destination: dest,
      );
      if (result == null || result.points.length < 2 || !mounted) return;
      // The rider can board (or the driver arrive) while this fetch is in
      // flight. Splicing a driver→pickup route on top of the trip route —
      // or the reverse — would put a wrong line on the map, so a leg change
      // discards this answer; the next off-route check refetches.
      if ((_phase == _TrackPhase.arriving) != toPickup) {
        debugPrint('[RiderTracking] Reroute discarded — leg changed mid-fetch');
        return;
      }

      // Partial splice: the stretch between where the driver left the old
      // route and where the new route rejoins it is the ONLY geometry that
      // changes. The already-driven part keeps its usual treatment (erased
      // behind the car), the untouched tail stays pixel-identical.
      //
      // ARRIVING is the exception (user report 2026-08-04, the "straight
      // line" screenshot): that leg has no erase-behind-the-car, so the
      // splice's head→driver connector stays VISIBLE — the old road plus
      // a long straight jump doubling back over the map. Replace the
      // whole line there; the crossfade repaints the fresh driver→pickup
      // road and a full repaint can never draw a connector.
      final spliced = toPickup
          ? result.points
          : RouteSplice.splice(
              oldRoute: _routePts,
              newRoute: result.points,
              driverPos: driverPos,
            );
      await _applyReroutedPolyline(spliced);

      // ETA base. result.durationSeconds covers ONLY the fresh
      // driver→destination stretch, but the spliced polyline still carries
      // the already-driven head, so the ETA formula's remaining-fraction is
      // < 1. Storing the raw value would discount the remaining time TWICE
      // (10 min left at 60% driven showed as 4 min). Rescale to the
      // full-route equivalent so duration × fraction == the router's answer
      // at this instant and keeps decaying as the car advances. In the
      // no-rejoin wholesale-replacement case _traveledM ≈ 0 and the scale
      // is ≈ 1 — the raw value, unchanged.
      final dur = result.durationSeconds;
      final total = _segDist.isNotEmpty ? _segDist.last : 0.0;
      final remainM = (total - _traveledM).clamp(0.0, total);
      if (dur != null && dur > 0 && remainM > 1.0) {
        _routeDurationSec = (dur * total / remainM).round();
      } else {
        _routeDurationSec = dur;
      }
    } catch (e) {
      debugPrint('[RiderTracking] Reroute error: $e');
    } finally {
      _rerouteInProgress = false;
    }
  }

  /// Push the screen's current route into the modular map component.
  ///
  /// The two hold separate copies and only initRoute() ever synced them —
  /// once, at map creation. Every later swap left TrackingMapRoute drawing
  /// and erasing against the first route it ever saw. Call this right
  /// after any assignment to `_routePts`.
  void _syncRouteToMap({bool resetDraw = true}) {
    if (_routePts.length < 2) return;
    _mapRoute?.setActiveRoute(_routePts, resetDraw: resetDraw);
  }

  /// Where along the freshly-built route the car should resume from.
  ///
  /// Every route swap used to reset traveled distance to 0, which is only
  /// right when the driver is genuinely at the new route's origin (leaving
  /// the pickup). For routes fetched asynchronously it is wrong: the
  /// origin is wherever the driver stood when the request went out, and
  /// they have been driving ever since. Projecting the live position onto
  /// the new geometry keeps the car exactly where it is drawn.
  ///
  /// Call AFTER [_buildSegDist] — the projection reads `_segDist`.
  double _startMOnCurrentRoute() {
    if (_segDist.isEmpty || _routePts.length < 2) return 0;
    // No GPS yet — the route origin is the best guess we have.
    if (_driverPos.latitude == 0 && _driverPos.longitude == 0) return 0;
    return _projectOntoRoute(_driverPos).clamp(0.0, _segDist.last);
  }

  /// Fetch road-following route from driver's current position to pickup
  /// for Uber-style approach visualization during arriving phase.
  ///
  /// One retry with a short backoff on failure — and if that also fails,
  /// NO straight-line stand-in: a line that cuts across blocks lies to the
  /// rider. The dimmed trip route and the pins stay on screen either way.
  Future<void> _fetchApproachRoute(LatLng driverPos) async {
    if (_approachRouteFetching || _approachRouteFetched || _approachRouteFailed) return;
    _approachRouteFetching = true;
    debugPrint('[RiderTracking] Fetching approach route: driver(${driverPos.latitude.toStringAsFixed(5)},${driverPos.longitude.toStringAsFixed(5)}) → pickup');
    try {
      final ds = DirectionsService(ApiKeys.webServices);
      var result = await ds.getRoute(
        origin: driverPos,
        destination: widget.pickupLatLng,
      );
      if ((result == null || result.points.length < 2) && mounted) {
        await Future.delayed(const Duration(milliseconds: 800));
        if (mounted) {
          result = await ds.getRoute(
            origin: driverPos,
            destination: widget.pickupLatLng,
          );
        }
      }
      if (result == null || result.points.length < 2 || !mounted) {
        _approachRouteFetching = false;
        if (mounted) _approachRouteFailed = true;
        return;
      }
      _approachRouteFetched = true;
      _approachRouteFetching = false;
      _approachRouteFailed = false;

      // The straight driver→pickup stopgap line _updateApproachLine drew
      // while this fetch was in flight is superseded by the road route
      // below. _updateApproachLine early-returns once _approachRouteFetched
      // is set, so nothing else ever removes it — delete it here or the
      // rider sees two yellow lines: the straight one cutting across
      // blocks and the real road route.
      unawaited(_mapRoute?.removeApproach());

      // Keep trip route as dimmed background (already drawn in _updateStaticAnnotationsOnce).
      // Set approach route as the active route for car tracking.
      _routePts = result.points;
      _buildSegDist();
      _syncRouteToMap();
      // Start the car where the driver IS, not at the route's origin.
      //
      // This request is async: the driver kept driving while it was in
      // flight, so the route's origin is where they WERE when it left.
      // Zeroing here snapped the car backwards by however far they had
      // travelled — a visible teleport at the exact moment the approach
      // line appears, which is the first thing the rider watches.
      _traveledM = _startMOnCurrentRoute();
      _tgtTraveledM = _traveledM;
      // _velocityMps is a scalar along the route, so it survives the swap.
      // Zeroing it stalled the car until the next GPS packet.
      _directTargetPos = null;
      _directTargetBearing = null;

      // Initial ETA from approach route — prefer traffic-aware duration from API
      _distanceMiles = result.distanceMeters / 1609.34;
      _routeDurationSec = result.durationSeconds;
      if (_routeDurationSec != null && _routeDurationSec! > 0) {
        _etaMinutes = (_routeDurationSec! / 60.0).ceil().clamp(1, 999);
      } else {
        _etaMinutes = (_distanceMiles / 0.4).ceil().clamp(1, 999);
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

      // Fit camera to show driver + pickup + dropoff — but only while
      // waiting for the driver. Once the rider is aboard the camera is
      // chasing the car, and a late approach-route fetch landing here
      // would yank it back out to an overview mid-ride.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_phase == _TrackPhase.onTrip ||
            _phase == _TrackPhase.nearDestination) {
          return;
        }
        _fitRouteBounds();
      });

      debugPrint('[RiderTracking] Approach route ready: ${_routePts.length} pts, ${_distanceMiles.toStringAsFixed(1)} mi, ETA $_etaMinutes min');
    } catch (e) {
      debugPrint('[RiderTracking] Approach route fetch error: $e');
      _approachRouteFetching = false;
      _approachRouteFailed = true;
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
    // Back in the dispatch queue: the assigned driver handed the trip back
    // (their app failed to open it, or they released it). There was no
    // branch for this at all, so the screen kept rendering the old driver
    // — name, photo, plate, "meet your driver" — for someone who was never
    // coming. The rider only found out when nobody arrived.
    final isBackInQueueStatus = status == 'requested';

    debugPrint('[RiderTracking] ⚡ STATUS UPDATE: raw="$rawStatus" → normalized="$status" (phase=$_phase, confirmShown=$_confirmPickupShown, driverId=$did)');

    // ═══════════════════════════════════════════════════════════════════════
    //  BACK IN QUEUE — the driver handed the trip back to dispatch.
    // ═══════════════════════════════════════════════════════════════════════
    if (isBackInQueueStatus) {
      // Only meaningful while still waiting for pickup. Once the rider is
      // aboard, a stray "requested" is stale data, not a real hand-back —
      // and acting on it would wipe the driver mid-ride.
      if (_phase == _TrackPhase.onTrip ||
          _phase == _TrackPhase.nearDestination ||
          _phase == _TrackPhase.completed) {
        debugPrint('[RiderTracking] ⏭️ requested ignored — phase=$_phase');
        return;
      }
      if (_backInQueueShown) return;
      _backInQueueShown = true;
      debugPrint('[RiderTracking] ↩️ TRIP RETURNED TO DISPATCH — back to searching');

      // Drop the old driver's live feed before leaving — the screen is
      // about to pop, but a late RTDB event must not repaint a car that
      // was reassigned.
      _rtdbDriverLocSub?.cancel();
      _rtdbDriverLocSub = null;
      _rtdbDriverId = null;
      _mapCar?.clear();

      // Back to the ride request screen's "Looking for your driver" card
      // (user spec 2026-08-04) — it used to stay HERE with a blanked
      // driver card, which read as broken. The pop result tells
      // _goToTracking's continuation to re-enter the searching phase and
      // re-arm the dispatch poll; dispatch is already re-cascading the
      // same trip to the next driver.
      if (mounted) {
        Navigator.of(context).maybePop('driver_released');
      }
      return;
    }

    // A driver is assigned again after a hand-back — allow the next one.
    if (_backInQueueShown && (did != null && did.isNotEmpty)) {
      _backInQueueShown = false;
      if (_searchingNewDriver) _setState(() => _searchingNewDriver = false);
    }

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
    //  ARRIVED — driver has confirmed arrival. Update map phase smoothly;
    //  the bottom card shows "Confirm Pickup" inline (no overlay screen).
    // ═══════════════════════════════════════════════════════════════════════
    if (isArrivedStatus) {
      // Ignore if rider already confirmed (phase is onTrip or later) or trip done.
      if (_phase == _TrackPhase.onTrip ||
          _phase == _TrackPhase.nearDestination ||
          _phase == _TrackPhase.completed) {
        debugPrint('[RiderTracking] ⏭️ arrived ignored — phase=$_phase (already past pickup)');
        return;
      }
      debugPrint('[RiderTracking] 🎯 DRIVER ARRIVED — updating map to arrived phase');
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
      // Show fullscreen pickup confirmation overlay (RiderConfirmPickupScreen)
      _showRiderConfirmPickup();
      if (!_arrivedNotifSent) {
        _arrivedNotifSent = true;
        LocalDataService.addNotification(
          title: 'Your driver has arrived',
          message: '${widget.driverName.split(' ').first} is waiting at the pickup spot in a ${widget.vehicleColor} ${widget.vehicleModel}.',
          type: 'ride',
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
        // Driver skipped the arrived signal — transition directly to onTrip.
        // No overlay; the map stays fluid.
        _transitionToOnTrip();
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
      // Without this the map component keeps the approach route and its
      // own already-true draw flag, so the pickup→dropoff line is never
      // drawn — the rider rides to the destination with no route on
      // screen at all.
      _syncRouteToMap();
    }
    _traveledM = 0;
    _tgtTraveledM = 0;
    // Do NOT zero _velocityMps here. The chase camera reads it the very next
    // frame to decide the target bearing: speed < 1 m/s means "parked, hold
    // heading", and the heading it would hold at trip start is the one the
    // arrived phase forced (north) — the camera then swings in sideways.
    // Keeping the last measured speed lets the first frames chase the real
    // heading; when there never was one, the camera falls back to the route
    // bearing (see updateChaseFrame's routeBearing).
    _approachRouteFetched = false;
    // A fresh trip leg re-arms the approach fetch for any later hand-back
    // to the arriving phase; the no-straight-line rule stays regardless.
    _approachRouteFailed = false;
    // The off-route clock was measured against the APPROACH polyline. It
    // survives the arrived phase untouched (the hysteresis band and the
    // !canReroute early-return both keep the timestamp), so without this
    // reset the trip leg's first >45 m fix — common right at boarding,
    // with the pin off-road and GPS still settling — would pass the 2.5 s
    // sustain instantly against a minutes-old timestamp and fire a reroute
    // from a noise position, killing the trip route's progressive draw.
    _offRouteSince = null;
    _lastRerouteAt = null;
    // The dimmed driver→pickup line _fetchApproachRoute drew lives in the
    // legacy _approachAnnot field, which the modular _mapRoute component
    // does not track — and _updateApproachLine only ever removes the
    // modular one. Left here, that stale line survived the route swap and
    // stayed on the map for the whole trip: the second yellow line next
    // to the real route in the rider's screenshot.
    final approachMgr = _polylineAnnotMgr;
    if (approachMgr != null && _approachAnnot != null) {
      try { approachMgr.delete(_approachAnnot!); } catch (_) {}
      _approachAnnot = null;
    }
    _routeDurationSec = null;
    if (_segDist.isNotEmpty) {
      final totalRouteM = _segDist.last;
      _distanceMiles = totalRouteM / 1609.34;
      _etaMinutes = (_distanceMiles / 0.4).ceil().clamp(1, 999);
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
      // The driver pressed Start: flash "driver detectado" (green) on the
      // Find-My overlay FIRST, then fade the page out — found, then gone,
      // never a snap (user spec 2026-08-05). The 900 ms beat is what
      // makes it read as an answer instead of the screen vanishing.
      RiderConfirmPickupScreen.externalStartPulse.value++;
      Future.delayed(const Duration(milliseconds: 900), () {
        if (!mounted || !_showPickupOverlay) return;
        // Guard: only reverse if the controller is completed (overlay
        // fully shown). If it's already animating or dismissed, skip to
        // avoid conflicts.
        if (_pickupOverlayCtrl.status == AnimationStatus.completed ||
            _pickupOverlayCtrl.status == AnimationStatus.forward) {
          _pickupOverlayCtrl.reverse().then((_) {
            if (mounted) _setState(() => _showPickupOverlay = false);
          });
        } else {
          // Already dismissed or reversing — just hide immediately
          _setState(() => _showPickupOverlay = false);
        }
      });
    }
    _startRideAnimationDone = false;
    _startStartRideAnimation();
    // Start periodic traffic-aware route refresh for accurate ETA
    _startTrafficRefreshTimer();
  }

  /// Periodic traffic-aware route refresh — fetches live traffic data
  /// every 2 minutes to keep ETA accurate during the trip.
  void _startTrafficRefreshTimer() {
    _trafficRefreshTimer?.cancel();
    _trafficRefreshTimer = Timer.periodic(const Duration(minutes: 2), (_) async {
      if (!mounted || _phase != _TrackPhase.onTrip && _phase != _TrackPhase.nearDestination) {
        _trafficRefreshTimer?.cancel();
        return;
      }
      // Only refresh if we have driver position and haven't refreshed recently
      if (_driverPos.latitude == 0 && _driverPos.longitude == 0) return;
      try {
        final ds = DirectionsService(ApiKeys.webServices);
        final result = await ds.getRoute(
          origin: _driverPos,
          destination: widget.dropoffLatLng,
        );
        if (result != null && result.durationSeconds != null && result.durationSeconds! > 0) {
          _routeDurationSec = result.durationSeconds;
          _routePts = result.points;
          _buildSegDist();
          // resetDraw: false — the line is already on screen and being
          // erased behind the car. This only refreshes the geometry the
          // erase is computed against; redrawing would flash it.
          _syncRouteToMap(resetDraw: false);
          // The fresh route starts AT the driver, so progress along it
          // restarts near zero. Keeping the old _traveledM (absolute along
          // the previous, longer polyline) shrank the remaining fraction
          // toward 0 — ETA pinned at the 1-min clamp and the phase flipped
          // to nearDestination early — and the max() ratchet in the GPS
          // handler then blocked any downward correction.
          _traveledM = _startMOnCurrentRoute();
          _tgtTraveledM = _traveledM;
          // Recalculate ETA with fresh traffic data
          final fraction = ((_segDist.last - _traveledM) / _segDist.last).clamp(0.0, 1.0);
          _etaMinutes = (_routeDurationSec! * fraction / 60.0).ceil().clamp(1, 999);
          _setState(() {});
          debugPrint('[RiderTracking] Traffic refresh: ETA updated to $_etaMinutes min');
        }
      } catch (e) {
        debugPrint('[RiderTracking] Traffic refresh failed: $e');
      }
    });
  }

  /// Show the rider confirmation pickup overlay when driver has arrived.
  /// Uses inline Stack overlay (not Navigator.push) so it always appears,
  /// even during route transitions or when the Navigator is busy.
  /// Fades in smoothly with slide-up animation.
  void _showRiderConfirmPickup() {
    if (!mounted || _confirmPickupShown) return;
    _confirmPickupShown = true;
    _setState(() => _showPickupOverlay = true);

    // Start the entrance only once the overlay has been through a full
    // frame, invisible.
    //
    // RiderConfirmPickupScreen is not a light widget: eight animation
    // controllers, three staggered ripple rings and a network avatar all
    // come up in its initState. Building, laying out and rasterising that
    // for the first time costs several frames — and an AnimationController
    // measures wall-clock, not frames. Starting it in the same breath as
    // the mount meant the 450 ms curve had already run most of its length
    // by the time the first pixel appeared, so the screen arrived at
    // three-quarters opacity, half-way through its slide: a hard cut with
    // a torn frame in the middle of it, which is precisely how the rider
    // described it.
    //
    // One frame of delay costs 16 ms and buys the whole animation.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_showPickupOverlay) return;
      _pickupOverlayCtrl.forward(from: 0);
    });
  }

  /// Listen to driver GPS from Firebase RTDB for sub-200ms updates.
  void _startRtdbDriverListener(String driverId) async {
    _rtdbDriverLocSub?.cancel();
    _rtdbDriverId = driverId;
    // Ensure Firebase Auth so RTDB rules (auth != null) pass
    if (FirebaseAuth.instance.currentUser == null) {
      try { await FirebaseAuthRecovery.ensureSignedIn(); }
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
        _rtdbNullRetryTimer?.cancel();
        _rtdbNullRetryTimer = Timer(const Duration(seconds: 5), () {
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
      // Fix 3: successful update — reset fail count and restore normal 8s polling
      if (_rtdbFailCount > 0) {
        _rtdbFailCount = 0;
        _rtdbReconnectTimer?.cancel();
        _statusPollTimer?.cancel();
        // C6 fix: defensive check — don't re-create the poll timer if the
        // trip is already completed (a late RTDB event could otherwise
        // restart polling on a dead trip forever).
        if (mounted && _phase != _TrackPhase.completed) {
          _statusPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
            _pollBackendTripStatus();
          });
        }
      }
      _markChannelAlive();
      _onRealDriverLocation(LatLng(lat, lng), bearing: bearing, speed: speed,
          timestampMs: _fixTimestampMs(data['timestamp']));
    }, onError: (e) {
      debugPrint('[RiderTracking] RTDB stream error: $e');
      _pollFailCount++;
      _rtdbFailCount++;
      // permission-denied → session expired. Recycle it for real so the
      // reconnect below actually gets a fresh token (see
      // FirebaseAuthRecovery — the old call handed back the same user).
      final isPermDenied = e is FirebaseException && e.code == 'permission-denied';
      if (isPermDenied || e.toString().contains('permission-denied')) {
        FirebaseAuthRecovery.refreshAnonymousSession().ignore();
      }
      if (_shouldFlagConnectionLost) {
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
      // Only archive the trip chat if the RIDER wrote at least once —
      // trips where the rider never messaged the driver leave no inbox record.
      final riderWrote = msgs.any((m) => (m['senderRole'] ?? '') == 'rider');
      if (!riderWrote) return;
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
        // Trip-chat records auto-delete 2 hours after the trip ends.
        'expiresAt': Timestamp.fromDate(
            DateTime.now().add(const Duration(hours: 2))),
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
      // No persisted position — fetch from backend for instant car display.
      // The car IS the driver; it must appear at the driver's actual location.
      _driverPos = const LatLng(0, 0);
      _animPos = _driverPos;
      // Try to get driver's last known position from backend immediately
      if (widget.tripId != null) {
        unawaited(_fetchInitialDriverLocation(widget.tripId!));
      }
    }

    // Calculate remaining distance — use route duration when available
    double remainingM = _segDist.isNotEmpty ? _segDist.last - _traveledM : 0;
    _distanceMiles = remainingM / 1609.34;
    if (_routeDurationSec != null && _routeDurationSec! > 0 && _segDist.isNotEmpty && _segDist.last > 0) {
      final fraction = (remainingM / _segDist.last).clamp(0.0, 1.0);
      _etaMinutes = (_routeDurationSec! * fraction / 60.0).ceil().clamp(1, 999);
    } else {
      _etaMinutes = (_distanceMiles / 0.4).ceil().clamp(1, 999);
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
        _etaMinutes = storedEta.clamp(1, 999);
      } else if (_routeDurationSec != null && _routeDurationSec! > 0) {
        _etaMinutes = (_routeDurationSec! / 60.0).ceil().clamp(1, 999);
      } else {
        _etaMinutes = (_distanceMiles / 0.4).ceil().clamp(1, 999);
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

    // ── The driver pages' motion engine owns the car ──
    //
    // This used to be three hand-rolled lerp branches (no route / arriving /
    // constant-velocity route advance) plus an off-route fallback — and none
    // of them had a standstill hold, so a parked driver's GPS wander moved
    // the pin and the chase camera after it, all day, every fix. The engine
    // is the same SmoothMotion the driver's own pages run: glide at the
    // measured speed while the car rolls, swallow wander while it is parked,
    // freeze the extrapolation when the feed goes quiet.
    _carMotion.tick(dt);
    if (_carMotion.hasPosition) {
      _animPos = LatLng(_carMotion.lat!, _carMotion.lng!);
      _driverPos = _animPos;
      _animBearing = _carMotion.bearing;
      _driverBearing = _animBearing;
      // Route progress is derived from the smoothed position, never driven:
      // ETA, remaining distance and the route erase all read this.
      if (_segDist.isNotEmpty) {
        _traveledM = _projectOntoRoute(_driverPos).clamp(0.0, _segDist.last);
      }
    }

    // Update map annotations directly — no setState needed (avoids 60fps widget rebuilds)
    // NOTE: _throttleBoundsFit() removed from interpolation loop — camera is now
    // driven by _cameraFollowTimer (1500ms) to prevent animation overlap jitter.
    _updateCarSmooth(); // fast path: only car GeoJSON
    _updateStaticAnnotationsOnce(); // slow path: pins + route, created once
    _eraseRouteBehindCar(); // progressive route erase (throttled internally)
    _updateApproachLine(); // dashed approach line driver→pickup

    // ── Idle detection: pause ticker only when trip is completed ──
    // NEVER stop the ticker during active phases (arriving, arrived, onTrip,
    // nearDestination). The ticker must be awake to process the next RTDB GPS
    // update instantly (no 1-frame delay on restart). Stopping during active
    // phases causes the car to freeze until the next GPS packet wakes it up.
    final isCompleted = _phase == _TrackPhase.completed;
    if (isCompleted && _carMotion.isAtTarget) {
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

    _routeFadeJob?.cancel();
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

    // Chase the car, don't frame the whole route.
    //
    // This used to fit the pickup→dropoff bounds, so the moment the driver
    // pressed Start Ride the camera pulled way out to a flat overview of
    // the entire trip — the rider's own car reduced to a speck for the
    // whole ride. The line above already says "skip to follow mode
    // immediately"; the fit contradicted it.
    _shouldFollowDriver = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startCameraFollowTracking();
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
    // Was _fitRouteBounds() — the exact opposite of what the name promises,
    // and of what a "follow" phase should do.
    _shouldFollowDriver = true;
    _startCameraFollowTracking();
  }

  /// Start real-time camera tracking.
  ///
  /// In onTrip/nearDestination we now use a 25 fps navigation chase ticker
  /// (Uber-style: bearing follows the car, gentle 20° tilt, adaptive zoom,
  /// driver anchored low on screen). In arriving/final states the existing
  /// bounds-fit paths keep pickup + dropoff visible.
  void _startCameraFollowTracking() {
    _cameraFollowTimer?.cancel();
    _startCameraTicker();
    // The ticker is enough for continuous chase; no periodic flyTo re-frame
    // is needed, which removes the remaining source of camera jumps.
  }

  /// Legacy helper kept for non-chase states. Now used only by the safety
  /// re-frame timer and manual recenter.
  void _followDriver(LatLng position, double bearing) {
    if (_map == null || !mounted) return;
    if (position.latitude == 0 && position.longitude == 0) return;
    _fitRouteBounds();
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

  /// Fetch driver's last known location from backend for instant car display.
  /// Called on screen open when no persisted position exists.
  Future<void> _fetchInitialDriverLocation(int tripId) async {
    try {
      final loc = await ApiService.getDriverLocation(tripId);
      if (loc == null || !mounted) return;
      
      final lat = (loc['lat'] as num?)?.toDouble();
      final lng = (loc['lng'] as num?)?.toDouble();
      if (lat == null || lng == null || lat == 0 || lng == 0) return;
      
      final pos = LatLng(lat, lng);
      final heading = (loc['heading'] as num?)?.toDouble() ?? 0.0;
      
      debugPrint('[RiderTracking] Initial driver location from backend: $lat, $lng');
      
      // Set position immediately — car will appear on next _updateCarSmooth tick
      _driverPos = pos;
      _animPos = pos;
      _animBearing = heading;
      _driverBearing = heading;
      _directTargetPos = pos;
      _directTargetBearing = heading;
      // Seed the engine from the same fix so its first live packet glides
      // from here instead of snapping.
      _carMotion.snapTo(lat, lng, bearing: heading);
      
      // Trigger car creation immediately
      if (_carPngBytes != null && _carAnnotMgr != null) {
        _updateCarSmooth();
      }
      
      // Fetch approach route from this position to pickup
      if (_phase == _TrackPhase.arriving &&
          !_approachRouteFetched &&
          !_approachRouteFetching &&
          !_approachRouteFailed) {
        unawaited(_fetchApproachRoute(pos));
      }
    } catch (e) {
      debugPrint('[RiderTracking] Failed to fetch initial driver location: $e');
    }
  }
}
