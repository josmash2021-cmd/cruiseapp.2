part of 'home_screen.dart';

// ════════════════════════════════════════════════════════════
//  CONTROLLER — data, navigation, shortcuts, scheduling
// ════════════════════════════════════════════════════════════

extension _HomeScreenController on _HomeScreenState {

  void _onPhotoChanged() {
    if (!mounted) return;
    _setState(() {
      _photoPath = UserSession.photoNotifier.value;
      _photoUrl = UserSession.photoUrlNotifier.value;
    });
  }

  // --- Service Zone support ---

  void _listenServiceZones() {
    _zonesSub = FirebaseFirestore.instance
        .collection('config')
        .doc('serviceZones')
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          final states = (snap.data()?['activeStates'] as List<dynamic>? ?? [])
              .map((s) => s.toString())
              .toSet();
          _setState(() {
            _activeServiceStates = states;
            // If no states configured → allow all (feature not yet set up)
            if (states.isEmpty) {
              _serviceZoneActive = true;
            } else if (_userStateName.isNotEmpty) {
              _serviceZoneActive = states.contains(_userStateName);
            }
          });
        });
  }

  /// Refresh GPS in background after using pre-loaded position
  void _refreshGpsInBackground() {
    Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    ).then((pos) {
      if (!mounted) return;
      _currentLatLng = LatLng(pos.latitude, pos.longitude);
      _animateToLocation(_currentLatLng!);
    }).catchError((_) {});
    // Start continuous location stream
    _locationSub?.cancel();
    _locationSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((Position p) {
      if (!mounted) return;
      final ll = LatLng(p.latitude, p.longitude);
      _currentLatLng = ll;
      _animateToLocation(ll);
    });
  }

  // ─── Ride progress countdown ───

  void _startCountdown(int etaMinutes) {
    _totalSeconds = etaMinutes * 60;
    _remainingSeconds = _totalSeconds;
    _tripStartTime = DateTime.now();
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted) return;
        if (_remainingSeconds <= 0) {
          _countdownTimer?.cancel();
          _loadSavedData(); // refresh active ride state → may unlock panel
          return;
        }
        _setState(() {
          _remainingSeconds--;
        });
      },
    );

    // Draw route on home screen map + start driver tracking
    if (_activeRide != null && _miniMapController != null) {
      _drawRouteOnMap();
      _listenToDriverLocation();
    }

    // Ensure fade controller is at full opacity for active ride
    _rideFadeCtrl.value = 1.0;
  }

  // ─── Driver location tracking for active trip ───

  void _listenToDriverLocation() {
    if (_activeRide == null || _miniMapController == null) return;
    
    // Cancel existing subscription
    _driverLocationSub?.cancel();
    _tripDocSub?.cancel();
    _trackedDriverId = null;
    
    // Listen to driver location from Firestore (ride document has driver_id)
    final tripId = _activeRide!.firestoreTripId;
    if (tripId == null) return;

    // Get driver ID from trip data first, then subscribe to their location
    _tripDocSub = FirebaseFirestore.instance
        .collection('trips')
        .doc(tripId)
        .snapshots()
        .listen((tripSnap) async {
      if (!mounted) return;
      
      final driverId = tripSnap.data()?['driver_id']?.toString();
      if (driverId == null) return;
      if (_trackedDriverId == driverId && _driverLocationSub != null) return;
      _trackedDriverId = driverId;

      // Subscribe to this driver's location in RTDB
      _driverLocationSub?.cancel();
      _driverLocationSub = FirebaseDatabase.instance
          .ref('driver_locations/$driverId')
          .onValue
          .listen((event) {
        if (!mounted) return;
        
        final data = event.snapshot.value as Map<dynamic, dynamic>?;
        if (data == null) return;

        final newLat = (data['lat'] as num?)?.toDouble() ?? 0.0;
        final newLng = (data['lng'] as num?)?.toDouble() ?? 0.0;
        final bearing = (data['bearing'] as num?)?.toDouble() ?? 0.0;

        _setState(() {
          _driverLocation = LatLng(newLat, newLng);
          _driverBearing = bearing;
        });

        // Animate driver car to new position
        _animateDriverCar(LatLng(newLat, newLng), bearing);
      });
    });

    // Also listen for trip completion
    _tripStatusSub?.cancel();
    _tripStatusSub = FirebaseFirestore.instance
        .collection('trips')
        .doc(tripId)
        .snapshots()
        .listen((tripSnap) {
      if (!mounted) return;
      
      final status = tripSnap.data()?['status']?.toString() ?? '';
      if (status == 'completed') {
        _onTripCompleted();
      }
    });
  }

  void _animateDriverCar(LatLng target, double bearing) {
    // Start from current interpolated position
    _driverAnimFrom = _interpolatedDriverLoc;
    _driverAnimTo = target;
    _driverAnimProgress = 0.0;

    // Restart ticker if needed
    if (_driverTicker != null && _driverTicker!.isActive) {
      _driverAnimNeedsRestart = true;
    } else {
      _driverAnimNeedsRestart = true;
      _driverTicker?.dispose();
      _driverTicker = createTicker(_onDriverAnimTickWrapper);
      _driverTicker!.start();
    }

    // Update map annotation
    _updateDriverMarker(target, bearing);
  }

  void _onDriverAnimTickWrapper(Duration elapsed) {
    if (_driverAnimNeedsRestart) {
      _driverAnimStart = elapsed;
      _driverAnimNeedsRestart = false;
    }
    _onDriverAnimTick(elapsed);
  }

  void _onDriverAnimTick(Duration elapsed) {
    if (_driverAnimFrom == null || _driverAnimTo == null) return;
    final dt = (elapsed - _driverAnimStart).inMilliseconds;
    _driverAnimProgress = (dt / 500.0).clamp(0.0, 1.0); // 500ms interpolation
    
    if (!mounted) return;
    // Update map annotation directly — no full widget rebuild needed
    final pos = _interpolatedDriverLoc;
    final annot = _driverCarAnnot;
    final mgr = _miniMapCarMgr;
    if (annot != null && mgr != null) {
      annot.geometry = mapbox.Point(
        coordinates: mapbox.Position(pos.longitude, pos.latitude),
      );
      mgr.update(annot);
    }
  }

  Future<void> _updateDriverMarker(LatLng position, double bearing) async {
    final ctrl = _miniMapController;
    if (ctrl == null) return;

    try {
      // Ensure car annotation manager exists
      _miniMapCarMgr ??= await ctrl.annotations.createPointAnnotationManager();
      final mgr = _miniMapCarMgr;
      if (mgr == null) return;

      // Load car image bytes (cached after first load)
      if (_cachedCarBytes == null) {
        final rideType = (_activeRide?.rideName ?? '').toLowerCase();
        final carAsset = rideType == 'vip'
            ? 'assets/images/cruisert1.png'
            : rideType == 'premium'
                ? 'assets/images/cruisert2.png'
                : rideType == 'comfort'
                    ? 'assets/images/cruisert3.png'
                    : 'assets/images/cruisert2.png';
        final byteData = await rootBundle.load(carAsset);
        _cachedCarBytes = byteData.buffer.asUint8List();
      }
      final bytes = _cachedCarBytes!;

      if (_driverCarAnnot != null) {
        // Update existing annotation position
        _driverCarAnnot!.geometry = mapbox.Point(
          coordinates: mapbox.Position(position.longitude, position.latitude),
        );
        mgr.update(_driverCarAnnot!);
      } else {
        // Create new annotation
        _driverCarAnnot = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(
            coordinates: mapbox.Position(position.longitude, position.latitude),
          ),
          image: bytes,
          iconSize: 0.55,
          iconOffset: [0, 0],
          iconAnchor: mapbox.IconAnchor.CENTER,
        ));
      }

      // Update route progress based on driver position
      _updateRouteProgress(position);
    } catch (e) {
      debugPrint('Error updating driver marker: $e');
    }
  }

  /// Draw the gold route polyline on the home screen map.
  Future<void> _drawRouteOnMap() async {
    if (_rideRouteDrawn) return;
    final ride = _activeRide;
    final ctrl = _miniMapController;
    if (ride == null || ctrl == null) return;
    if (ride.routePoints.isEmpty) return;

    _rideRouteDrawn = true;
    _routeLatLngs = ride.routePoints.map((p) => LatLng(p[0], p[1])).toList();

    // Cap route endpoints to exact pin coordinates
    if (_routeLatLngs.length >= 2) {
      _routeLatLngs[0] = LatLng(ride.pickupLat, ride.pickupLng);
      _routeLatLngs[_routeLatLngs.length - 1] = LatLng(ride.dropoffLat, ride.dropoffLng);
    }

    try {
      // Create polyline annotation manager
      _miniMapPolyMgr ??= await ctrl.annotations.createPolylineAnnotationManager();
      final mgr = _miniMapPolyMgr;
      if (mgr == null) return;

      // Build coordinate list
      final coords = _routeLatLngs
          .map((ll) => mapbox.Position(ll.longitude, ll.latitude))
          .toList();
      if (coords.length < 2) return;

      // Draw gold route line
      _tripRouteAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
        geometry: mapbox.LineString(coordinates: coords),
        lineColor: const Color(0xFFFFD700).toARGB32(),
        lineWidth: 5.0,
        lineJoin: mapbox.LineJoin.ROUND,
      ));

      // Add dropoff pin at the end of the route
      await _addDropoffPin(ride);

      // Hide the gold location dot now that route is visible
      _updateMiniMapAnnotation();

      // Fit camera to show the whole route
      _fitCameraToRoute();
    } catch (e) {
      debugPrint('Error drawing route on home map: $e');
    }
  }

  /// Place a gold dropoff pin on the home map.
  Future<void> _addDropoffPin(ActiveRideInfo ride) async {
    final ctrl = _miniMapController;
    if (ctrl == null) return;
    if (ride.dropoffLat == 0 && ride.dropoffLng == 0) return;

    try {
      final pinMgr = _miniMapAnnotMgr ??
          await ctrl.annotations.createPointAnnotationManager();
      final pinBytes = await buildGoldenPinBytes(
        icon: Icons.location_on_rounded,
        size: 64,
      );
      _dropoffPinAnnot = await pinMgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(
          coordinates: mapbox.Position(ride.dropoffLng, ride.dropoffLat),
        ),
        image: pinBytes,
        iconSize: 0.7,
        iconAnchor: mapbox.IconAnchor.BOTTOM,
        iconOffset: [0, 0],
      ));
    } catch (e) {
      debugPrint('Error adding dropoff pin: $e');
    }
  }

  /// Fit the camera to show the full route with padding.
  void _fitCameraToRoute() {
    if (_routeLatLngs.isEmpty || _miniMapController == null) return;

    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final ll in _routeLatLngs) {
      if (ll.latitude < minLat) minLat = ll.latitude;
      if (ll.latitude > maxLat) maxLat = ll.latitude;
      if (ll.longitude < minLng) minLng = ll.longitude;
      if (ll.longitude > maxLng) maxLng = ll.longitude;
    }

    // Also include driver location if available
    if (_driverLocation != null) {
      final dl = _driverLocation!;
      if (dl.latitude < minLat) minLat = dl.latitude;
      if (dl.latitude > maxLat) maxLat = dl.latitude;
      if (dl.longitude < minLng) minLng = dl.longitude;
      if (dl.longitude > maxLng) maxLng = dl.longitude;
    }

    _miniMapController!.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(
          coordinates: mapbox.Position(
            (minLng + maxLng) / 2,
            (minLat + maxLat) / 2,
          ),
        ),
        zoom: _calculateZoomForBounds(minLat, maxLat, minLng, maxLng),
        pitch: 0,
        bearing: 0,
      ),
      mapbox.MapAnimationOptions(duration: 800),
    );
  }

  double _calculateZoomForBounds(double minLat, double maxLat, double minLng, double maxLng) {
    final latDiff = maxLat - minLat;
    final lngDiff = maxLng - minLng;
    final maxDiff = math.max(latDiff, lngDiff);
    if (maxDiff <= 0) return 15.0;
    // Approximate zoom: smaller bounds → higher zoom
    final zoom = 14.0 - (math.log(maxDiff * 111) / math.ln2);
    return zoom.clamp(10.0, 17.0);
  }

  /// Compute how far along the route the driver is (0.0→1.0).
  void _updateRouteProgress(LatLng driverPos) {
    if (_routeLatLngs.length < 2) return;

    double totalDist = 0;
    double closestDist = double.infinity;
    double distAtClosest = 0;
    double runningDist = 0;

    for (int i = 0; i < _routeLatLngs.length - 1; i++) {
      final a = _routeLatLngs[i];
      final b = _routeLatLngs[i + 1];
      final segLen = _haversine(a, b);
      totalDist += segLen;
    }

    runningDist = 0;
    for (int i = 0; i < _routeLatLngs.length - 1; i++) {
      final a = _routeLatLngs[i];
      final b = _routeLatLngs[i + 1];
      final segLen = _haversine(a, b);

      // Project driver onto this segment
      final proj = _projectOntoSegment(driverPos, a, b);
      final dist = _haversine(driverPos, proj);
      if (dist < closestDist) {
        closestDist = dist;
        distAtClosest = runningDist + _haversine(a, proj);
      }
      runningDist += segLen;
    }

    if (totalDist > 0) {
      final newProgress = (distAtClosest / totalDist).clamp(0.0, 1.0);
      // Only update if moving forward (prevent backward jumps)
      if (newProgress >= _routeProgress) {
        _routeProgress = newProgress;
      }
    }
  }

  /// Haversine distance in meters.
  static double _haversine(LatLng a, LatLng b) {
    const R = 6371000.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final sLat = math.sin(dLat / 2);
    final sLng = math.sin(dLng / 2);
    final h = sLat * sLat +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            sLng * sLng;
    return 2 * R * math.asin(math.sqrt(h));
  }

  /// Project point P onto segment AB, clamped to [A, B].
  static LatLng _projectOntoSegment(LatLng p, LatLng a, LatLng b) {
    final dx = b.longitude - a.longitude;
    final dy = b.latitude - a.latitude;
    if (dx == 0 && dy == 0) return a;
    final t = ((p.longitude - a.longitude) * dx + (p.latitude - a.latitude) * dy) /
        (dx * dx + dy * dy);
    final tc = t.clamp(0.0, 1.0);
    return LatLng(a.latitude + tc * dy, a.longitude + tc * dx);
  }

  /// Clear all route annotations from the home screen map.
  Future<void> _clearRouteFromMap() async {
    try {
      if (_tripRouteAnnot != null && _miniMapPolyMgr != null) {
        await _miniMapPolyMgr!.delete(_tripRouteAnnot!);
        _tripRouteAnnot = null;
      }
      if (_driverCarAnnot != null && _miniMapCarMgr != null) {
        await _miniMapCarMgr!.delete(_driverCarAnnot!);
        _driverCarAnnot = null;
      }
      if (_dropoffPinAnnot != null && _miniMapAnnotMgr != null) {
        await _miniMapAnnotMgr!.delete(_dropoffPinAnnot!);
        _dropoffPinAnnot = null;
      }
    } catch (_) {}
    _rideRouteDrawn = false;
    _routeProgress = 0.0;
    _routeLatLngs = [];
  }

  void _onTripCompleted() {
    if (!mounted) return;

    // Cancel subscriptions
    _driverLocationSub?.cancel();
    _tripStatusSub?.cancel();
    _driverTicker?.dispose();
    _countdownTimer?.cancel();

    // Fade out ride UI, then reset state
    _rideFadeCtrl.reverse().then((_) async {
      if (!mounted) return;

      // Clear map annotations
      await _clearRouteFromMap();

      _setState(() {
        _activeRide = null;
        _driverLocation = null;
      });

      // Reset map to home
      if (_miniMapController != null && _currentLatLng != null) {
        _miniMapController!.flyTo(
          mapbox.CameraOptions(
            center: mapbox.Point(
              coordinates: mapbox.Position(
                _currentLatLng!.longitude,
                _currentLatLng!.latitude,
              ),
            ),
            zoom: 15.0,
            pitch: 0,
            bearing: 0,
          ),
          mapbox.MapAnimationOptions(duration: 800),
        );
      }

      // Fade in normal content
      _rideFadeCtrl.forward();

      // Refresh saved data to update UI
      _loadSavedData();
    });
  }

  void _showPlaceOptions(String label, String address, VoidCallback editTap) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              address,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            // Edit Address
            _placeOptionBtn(Icons.edit_rounded, S.of(context).editAddressLabel, () {
              Navigator.pop(ctx);
              editTap();
            }),
            const SizedBox(height: 8),
            // Request a Ride
            _placeOptionBtn(Icons.directions_car_rounded, S.of(context).requestRideLabel, () {
              Navigator.pop(ctx);
              _requestRideToAddress(address);
            }, highlight: true),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  /// Open the search screen (photo 3) directly, then push RideRequestScreen
  /// with the pickup/dropoff results pre-filled.
  Future<void> _openSearchThenRide({String? rideId}) async {
    if (_activeRide != null) {
      _resumeActiveRide();
      return;
    }
    if (!await _ensureVerified()) return;
    if (!mounted) return;

    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      sharedAxisZRoute(
        PickupDropoffSearchScreen(
          initialPickupLat: _currentLatLng?.latitude,
          initialPickupLng: _currentLatLng?.longitude,
        ),
        opaque: false,
      ),
    );

    if (result == null || !mounted) return;

    final pickupDetails = result['pickup'] as PlaceDetails?;
    final dropoffDetails = result['dropoff'] as PlaceDetails?;
    final pickupLabel = result['pickupLabel'] as String? ?? '';
    final dropoffLabel = result['dropoffLabel'] as String? ?? '';

    if (dropoffDetails == null) return;

    // Use current location as pickup if search didn't provide one
    final effectivePickup = pickupDetails ?? (
      _currentLatLng != null
          ? PlaceDetails(
              address: pickupLabel.isNotEmpty ? pickupLabel : 'Current location',
              lat: _currentLatLng!.latitude,
              lng: _currentLatLng!.longitude,
            )
          : null
    );

    final effectiveDropoffLabel = dropoffLabel.isNotEmpty
        ? dropoffLabel
        : dropoffDetails.address;

    // Pre-fetch route in parallel while preparing navigation
    Future<RouteResult?>? routeFuture;
    if (effectivePickup != null) {
      final origin = LatLng(effectivePickup.lat, effectivePickup.lng);
      final dest = LatLng(dropoffDetails.lat, dropoffDetails.lng);
      routeFuture = DirectionsService(ApiKeys.webServices)
          .getRoute(origin: origin, destination: dest);
    }

    // Wait briefly for route — if it arrives fast, pass it; otherwise navigate without it
    RouteResult? preloadedRoute;
    if (routeFuture != null) {
      preloadedRoute = await routeFuture.timeout(
        const Duration(milliseconds: 800),
        onTimeout: () => null,
      );
    }

    if (!mounted) return;

    await Navigator.of(context).push(
      scaleExpandRoute(
        RideRequestScreen(
          initialPickupDetails: effectivePickup,
          initialDropoffDetails: dropoffDetails,
          initialPickupLabel: pickupLabel,
          initialDropoffLabel: effectiveDropoffLabel,
          initialDropoffAddress: effectiveDropoffLabel,
          initialRideId: rideId,
          preloadedRoute: preloadedRoute,
        ),
      ),
    );
    if (mounted) _loadSavedData();
  }

  // Map styles now use shared MapStyles.dark from config/map_styles.dart

  void _openScheduleFlow() => _showScheduleSheet();

  Future<void> _openScheduleSheet() => _showScheduleSheet();

  void _resumeActiveRide() {
    final ride = _activeRide;
    if (ride == null) return;
    Navigator.of(context).push(
      slideUpFadeRoute(
        RiderTrackingScreen(
          pickupLatLng: LatLng(ride.pickupLat, ride.pickupLng),
          dropoffLatLng: LatLng(ride.dropoffLat, ride.dropoffLng),
          routePoints: ride.routePoints.map((p) => LatLng(p[0], p[1])).toList(),
          driverName: ride.driverName,
          driverRating: ride.driverRating,
          vehicleMake: ride.vehicleMake,
          vehicleModel: ride.vehicleModel,
          vehicleColor: ride.vehicleColor,
          vehiclePlate: ride.vehiclePlate,
          vehicleYear: ride.vehicleYear,
          rideName: ride.rideName,
          price: ride.price,
          pickupLabel: ride.pickupLabel,
          dropoffLabel: ride.dropoffLabel,
          tripId: ride.tripId,
          firestoreTripId: ride.firestoreTripId,
          driverPhotoUrl: ride.driverPhotoUrl,
          driverId: ride.driverId,
          onTripComplete: () {
            LocalDataService.clearActiveRide();
            Navigator.of(context).pop();
            _loadSavedData();
          },
        ),
      ),
    );
  }

  /// Full-screen autocomplete address picker using PlacesService.
  Future<String?> _showAddressAutocomplete({
    required String title,
    required String hint,
  }) async {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _AddressAutocompleteSheet(
        title: title,
        hint: hint,
        currentLatLng: _currentLatLng,
      ),
    );
  }

  void _openTripReceipt(TripHistoryItem trip) {
    Navigator.of(
      context,
    ).push(sharedAxisVerticalRoute(TripReceiptScreen(trip: trip)));
  }
}
