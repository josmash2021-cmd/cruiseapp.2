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
      _setState(() {
        _currentLatLng = LatLng(pos.latitude, pos.longitude);
      });
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
      _setState(() => _currentLatLng = ll);
      _animateToLocation(ll);
    });
  }

  // ─── Ride progress countdown ───

  void _startCountdown(int etaMinutes) {
    _totalSeconds = etaMinutes * 60;
    _remainingSeconds = _totalSeconds;
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
