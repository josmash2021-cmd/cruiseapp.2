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
          if (_pollFailCount >= _maxPollFailsBeforeBanner && !_connectionLost) {
            _setState(() => _connectionLost = true);
          }
          return;
        }
        _pollFailCount = 0;
        if (_connectionLost) _setState(() => _connectionLost = false);
        _onTripStatusUpdate(data);
      },
      onError: (error) {
        debugPrint('[RiderTracking] Trip status listener error for $docId: $error');
        _pollFailCount++;
        if (mounted && _pollFailCount >= _maxPollFailsBeforeBanner && !_connectionLost) {
          _setState(() => _connectionLost = true);
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

      _tripSseSub?.cancel();
      _tripSseSub = ApiService.streamTripStatus(tripId).listen(
        (event) {
          if (!mounted || event.isEmpty) return;
          final status = (event['status']?.toString() ?? '').trim().toLowerCase();
          if (status.isEmpty) return;
          debugPrint('[RiderTracking] SSE trip_update status=$status');
          _onTripStatusUpdate(event);
        },
        onError: (error) {
          debugPrint('[RiderTracking] SSE listener error: $error');
        },
        onDone: () {
          debugPrint('[RiderTracking] SSE listener closed');
        },
      );

      _statusPollTimer?.cancel();
      _statusPollTimer = Timer.periodic(
        const Duration(seconds: 8),
        (_) => _pollBackendTripStatus(),
      );
      unawaited(_pollBackendTripStatus());
    } else {
      _statusPollTimer?.cancel();
      _tripSseSub?.cancel();
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
  }

  /// Process real-time driver location from RTDB.
  void _onRealDriverLocation(LatLng ll, {double? bearing}) {
    if (ll.latitude == 0 && ll.longitude == 0) return;

    // FIX 4: Smooth marker animation - start interpolation to new position
    if (_shouldFollowDriver) {
      _startSmoothMarkerAnimation(ll, bearing);
    }

    // Always try to snap GPS onto the route polyline.
    // Only fall back to raw GPS lerp when we truly have no route.
    if (_segDist.isNotEmpty && _routePts.length >= 2) {
      final projectedM = _projectOntoRoute(ll);
      // Accept projection when close enough to route (< 150m lateral)
      final snappedPos = _posAtDistUltraSmooth(projectedM.clamp(0.0, _segDist.last)).$1;
      final lateralM = _hav(ll, snappedPos) * 1609.34;
      if (lateralM < 150) {
        // Enforce forward-only: never jump backward (GPS noise can project behind)
        final clampedM = projectedM.clamp(0.0, _segDist.last);
        if (clampedM >= _traveledM - 5) {
          // Allow up to 5m backward tolerance for GPS jitter, otherwise only forward
          _tgtTraveledM = math.max(clampedM, _traveledM);
        }
        _directTargetPos = null; // on route — disable raw fallback
        _directTargetBearing = null;
      } else {
        // Too far from route — use raw GPS lerp as fallback
        _directTargetPos = ll;
        _directTargetBearing = bearing;
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
      // 0.4 mi/min ≈ 24 mph average urban speed
      _etaMinutes = (_distanceMiles / 0.4).ceil().clamp(1, 99);
      if (dist < 0.05 && _phase == _TrackPhase.arriving) {
        _setState(() {
          _phase = _TrackPhase.arrived;
          _etaMinutes = 0;
          _distanceMiles = 0;
        });
        _arrivedDotPulse.repeat(reverse: true);
        _handleDriverArrived();
        _showRiderConfirmPickup();
        if (!_arrivedNotifSent) {
          _arrivedNotifSent = true;
          _sendRideNotification(
            'Your driver has arrived',
            '${widget.driverName.split(' ').first} is waiting at the pickup spot in a ${widget.vehicleColor} ${widget.vehicleModel}.',
          );
        }
      }
    } else if (_phase == _TrackPhase.onTrip || _phase == _TrackPhase.nearDestination) {
      final dist = _hav(ll, widget.dropoffLatLng);
      // Use remaining route distance (road) when available, fallback to haversine
      if (_segDist.isNotEmpty && _traveledM >= 0) {
        final remainM = (_segDist.last - _traveledM).clamp(0.0, _segDist.last);
        _distanceMiles = remainM / 1609.34;
      } else {
        _distanceMiles = dist;
      }
      _etaMinutes = (_distanceMiles / 0.4).ceil().clamp(1, 99);
      // Transition to nearDestination when ETA <= 2 min
      if (_etaMinutes <= 2 && _phase == _TrackPhase.onTrip) {
        _setState(() => _phase = _TrackPhase.nearDestination);
      } else if (_etaMinutes > 2 && _phase == _TrackPhase.nearDestination) {
        // Transition back if driver moved away (re-routing)
        _setState(() => _phase = _TrackPhase.onTrip);
      }
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
    
    const steps = 45;
    const duration = Duration(milliseconds: 1200);
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
    }

    final rawStatus = data['status']?.toString() ?? '';
    final status = rawStatus.trim().toLowerCase();
    final hasArrivedTs = data['driverArrivedAt'] != null || data['driver_arrived_at'] != null;
    final hasStartedTs = data['startedAt'] != null || data['started_at'] != null;
    final hasCompletedTs = data['completedAt'] != null || data['completed_at'] != null;

    final isArrivedStatus =
        status == 'arrived' ||
        status == 'driver_arrived' ||
        status == 'arrived_pickup' ||
        status == 'arrived_at_pickup' ||
        hasArrivedTs;
    final isInTripStatus =
        status == 'in_trip' ||
        status == 'in_progress' ||
        status == 'rider_onboard' ||
        status == 'trip_started' ||
        hasStartedTs;
    final isCompletedStatus = status == 'completed' || hasCompletedTs;
    // Only trust the explicit status field for cancellation — never stale
    // timestamps alone, which can persist from previous Firestore merges.
    final isCancelledStatus =
        status == 'cancelled' || status == 'canceled';

    debugPrint('[RiderTracking] Firestore status update: "$rawStatus" normalized="$status" (phase=$_phase, driverId=$did)');
    if (isArrivedStatus && _phase == _TrackPhase.arriving) {
      _setState(() {
        _phase = _TrackPhase.arrived;
        _etaMinutes = 0;
        _distanceMiles = 0;
      });
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
      // Reset traveled distance for the new trip leg and recalculate ETA
      _traveledM = 0;
      _tgtTraveledM = 0;
      if (_segDist.isNotEmpty) {
        final totalRouteM = _segDist.last;
        _distanceMiles = totalRouteM / 1609.34;
        _etaMinutes = (_distanceMiles / 0.4).ceil().clamp(1, 99);
      }
      _setState(() {
        _phase = _TrackPhase.onTrip;
        _tripJustStarted = true;
      });
      _tripStartedTimer?.cancel();
      _tripStartedTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) _setState(() => _tripJustStarted = false);
      });
      _arrivedDotPulse.stop();
      _popOutPickupPin();
      _startStartRideAnimation();
    } else if (isInTripStatus &&
        _phase == _TrackPhase.nearDestination) {
      // Already near destination — don't reset to onTrip
      _arrivedDotPulse.stop(); // Stop pulsing dot animation
      _popOutPickupPin();
      // FIX 3 & 4: Start the route animation and camera phases when starting ride
      _startStartRideAnimation();
    } else if (isCompletedStatus && _phase != _TrackPhase.completed) {
      LocalDataService.clearActiveRide();
      _setState(() => _phase = _TrackPhase.completed);
      _arrivedDotPulse.stop();
      // Save trip chat to inbox before navigating away
      _saveChatToInbox();
      // Let the rider see the "Trip completed" state briefly before rating
      Future.delayed(const Duration(seconds: 3), () {
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
          driverPhotoUrl: _driverPhotoUrl ?? widget.driverPhotoUrl,
          driverId: widget.driverId,
          driverRating: widget.driverRating,
          vehiclePlate: widget.vehiclePlate,
          onConfirmed: () {
            _confirmPickupShown = false;
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
      // Throttle: max 5 updates/sec for smoother car animation
      final now = DateTime.now();
      if (lastRtdbUpdate != null &&
          now.difference(lastRtdbUpdate!).inMilliseconds < 200) {
        return;
      }
      lastRtdbUpdate = now;
      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      final bearing = (data['bearing'] as num?)?.toDouble();
      if (lat == null || lng == null) return;
      _pollFailCount = 0;
      if (_connectionLost) _setState(() => _connectionLost = false);
      _onRealDriverLocation(LatLng(lat, lng), bearing: bearing);
    }, onError: (_) {});
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
    // Navigate to rating immediately
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => RiderRatingScreen(
          driverName: widget.driverName,
          tripId: widget.tripId,
          fare: widget.price,
          driverPhotoUrl: _driverPhotoUrl ?? widget.driverPhotoUrl,
          driverUid: widget.driverId,
          dropoffLat: widget.dropoffLatLng.latitude,
          dropoffLng: widget.dropoffLatLng.longitude,
        ),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 500),
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
            status == 'driver_arrived') {
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
        case 'nearDestination':
          _phase = _TrackPhase.nearDestination;
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
    _etaMinutes = (_distanceMiles / 0.4).ceil().clamp(1, 99);

    if (!mounted) return;
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
      driverPhotoUrl: activeRide.driverPhotoUrl,
      driverId: activeRide.driverId,
      etaMinutes: activeRide.etaMinutes,
    );

    await LocalDataService.setActiveRide(updatedRide);
  }

  // Called every vsync frame via Ticker — GPU-synchronized, zero-jolt movement
  void _interpolate() {
    if (!mounted || _segDist.isEmpty) return;

    // ── Smooth exponential advance — buttery motion ──
    // Use exponential decay so the car accelerates toward the target
    // and decelerates as it approaches — no jolts, no teleports.
    final diff = _tgtTraveledM - _traveledM;
    // Exponential catch-up: 20% of remaining distance per frame.
    // Capped to prevent teleporting on large GPS jumps (>50m).
    final step = (diff * 0.20).clamp(-2.5, 2.5);
    if (diff.abs() < 0.05) {
      _traveledM = _tgtTraveledM;
    } else {
      _traveledM += step;
    }

    final (pos, brg) = _posAtDistUltraSmooth(_traveledM);

    // ── Bearing: smooth 22% rotation per frame — responsive yet fluid ──
    double db = brg - _animBearing;
    if (db > 180) db -= 360;
    if (db < -180) db += 360;
    final newBearing = (_animBearing + db * 0.22) % 360;

    _animPos = pos;
    _animBearing = newBearing;
    _driverPos = pos;
    _driverBearing = newBearing;

    // ── Direct-target lerp (GPS fallback — ONLY when off-route) ──
    final tgt = _directTargetPos;
    if (tgt != null) {
      const lerpFactor = 0.16; // smooth catch-up, never teleport
      final newLat = _animPos.latitude + (tgt.latitude - _animPos.latitude) * lerpFactor;
      final newLng = _animPos.longitude + (tgt.longitude - _animPos.longitude) * lerpFactor;
      final fallbackBearing = _directTargetBearing;
      final newBrg = _bearing(_animPos, LatLng(newLat, newLng));
      _animPos = LatLng(newLat, newLng);
      _driverPos = _animPos;
      final desiredBearing = newBrg != 0 ? newBrg : fallbackBearing;
      if (desiredBearing != null) {
        double dbo = desiredBearing - _animBearing;
        if (dbo > 180) dbo -= 360;
        if (dbo < -180) dbo += 360;
        _animBearing = (_animBearing + dbo * 0.18) % 360;
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

  /// Start the ride start animation:
  /// 1. Camera zooms out to show full route (800ms flyTo)
  /// 2. Dropoff pin appears
  /// Start the ride start animation sequence:
  /// 1. Camera top-down showing full route (800 ms flyTo)
  /// 2. Route draws progressively pickup → dropoff (2 s)
  /// 3. Camera flies to 45° centred on driver (1.5 s)
  /// 4. Route fades out (600 ms)
  /// 5. Route redraws from driver position → dropoff (2 s)
  /// 6. Enable 45° follow camera for real-time tracking
  void _startStartRideAnimation() {
    if (_startRideAnimationDone) return;
    _startRideAnimationDone = true;
    _startRidePhase = 1;

    _routeFadeTimer?.cancel();
    _routeOpacity = 1.0;

    if (_dropoffAnnot == null) {
      _dropoffPinAdded = false;
      _addDropoffPin();
    }

    // Remove the dimmed route — we'll draw a bright gloss one instead
    _removeDimmedRoute();

    // PHASE 2: Zoom out to top-down full route overview (800 ms flyTo)
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _fitRouteBounds();
    });

    // PHASE 3: Animated gloss route draw pickup → dropoff (2 s)
    Future.delayed(const Duration(milliseconds: 1000), () {
      if (!mounted) return;
      _startRidePhase = 2;
      _routeDrawDone = false;
      _startAnimatedRouteDraw();
    });

    // PHASE 4: Fly camera to 45° on driver (1.5 s)
    Future.delayed(const Duration(milliseconds: 3200), () {
      if (!mounted) return;
      _startRidePhase = 3;
      _flyToDriverAt45();
    });

    // PHASE 5: Fade out route (600 ms)
    Future.delayed(const Duration(milliseconds: 4800), () {
      if (!mounted) return;
      _startRidePhase = 4;
      _fadeRouteForRideStart();
    });

    // PHASE 6: Redraw route + enable 45° follow camera
    _startRidePhaseTimer?.cancel();
    _startRidePhaseTimer = Timer(const Duration(milliseconds: 5600), () {
      if (!mounted) return;
      _routeDrawDone = false;
      _startAnimatedRouteDraw(); // redraw from current driver position → dropoff
      _useNavCamera = true;      // switch _followDriver() to tilt mode
      _startRidePhase = 5;       // done — real-time tracking
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

  /// Start real-time camera tracking - follows driver every location update
  void _startCameraFollowTracking() {
    if (!_shouldFollowDriver || _map == null) return;
    
    _cameraFollowTimer?.cancel();
    _cameraFollowTimer = Timer.periodic(const Duration(milliseconds: 2000), (_) {
      if (!mounted || !_shouldFollowDriver || _map == null) return;
      _followDriver(_animPos, _animBearing);
    });
  }

  /// Smooth camera follow for driver position
  void _followDriver(LatLng position, double bearing) {
    // Always show full route overview so route stays centered between panels
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
}
