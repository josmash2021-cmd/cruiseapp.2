part of 'map_screen.dart';

// ════════════════════════════════════════════════════════════
//  CONTROLLER — location, search, ride logic, payment
// ════════════════════════════════════════════════════════════

extension _MapScreenController on _MapScreenState {

  void _handleAddressFocusChange() {
    if (!mounted || _stage != RideStage.plan) return;
    final focused = _pickupFocus.hasFocus || _dropoffFocus.hasFocus;
    if (_isAddressFieldFocused == focused) return;
    _setState(() {
      _isAddressFieldFocused = focused;
      _panelDragHeight = focused ? _panelMaxHeight(context) : null;
      _isPanelDragging = false;
    });

    if (!focused) {
      Future.microtask(() async {
        await _maybeAutoRouteFromInputs();
      });
    }
  }

  int _durationTextToMinutes(String value) {
    final lower = value.toLowerCase();
    final hoursMatch = RegExp(
      r'(\d+)\s*(h|hr|hrs|hour|hours)',
    ).firstMatch(lower);
    final minsMatches = RegExp(
      r'(\d+)\s*(m|min|mins|minute|minutes)',
    ).allMatches(lower).toList();

    var minutes = 0;
    if (hoursMatch != null) {
      minutes += (int.tryParse(hoursMatch.group(1) ?? '') ?? 0) * 60;
    }

    if (minsMatches.isNotEmpty) {
      final mins = int.tryParse(minsMatches.first.group(1) ?? '') ?? 0;
      minutes += mins;
    } else {
      final numberMatch = RegExp(r'(\d+)').firstMatch(lower);
      if (numberMatch != null) {
        minutes += int.tryParse(numberMatch.group(1) ?? '') ?? 0;
      }
    }

    return minutes.clamp(1, 300);
  }

  String _priceFromMinutes(int minutes, {double multiplier = 1.0}) {
    final hourlyTarget = 120.0;
    var computed = (minutes / 60.0) * hourlyTarget * multiplier;
    // Apply promo discount if active
    if (_promoActive && _promoDiscountPercent > 0) {
      computed = computed * (1 - _promoDiscountPercent / 100.0);
    }
    final rounded = (computed * 100).roundToDouble() / 100;
    return '\$${rounded.toStringAsFixed(2)}';
  }

  void _updateRidePricingFromDuration(String durationText) {
    final baseMinutes = _durationTextToMinutes(durationText);
    final vipMinutes = (baseMinutes * 0.85).ceil().clamp(1, 300);
    final premiumMinutes = baseMinutes;
    final comfortMin = (baseMinutes * 1.10).ceil().clamp(1, 300);
    final comfortMax = (baseMinutes * 1.45).ceil().clamp(comfortMin, 300);

    final vipEta = '$vipMinutes min';
    final premiumEta = '$premiumMinutes min';
    final comfortEta = '$comfortMin-$comfortMax min';

    _rides = [
      RideOption(
        name: 'VIP',
        vehicle: 'Suburban',
        price: _priceFromMinutes(vipMinutes, multiplier: 2.2),
        eta: vipEta,
        promoted: true,
      ),
      RideOption(
        name: 'Premium',
        vehicle: 'Camry',
        price: _priceFromMinutes(premiumMinutes, multiplier: 1.35),
        eta: premiumEta,
      ),
      RideOption(
        name: 'Comfort',
        vehicle: 'Fusion',
        price: _priceFromMinutes(comfortMax, multiplier: 0.92),
        eta: comfortEta,
      ),
    ];
    if (_selectedRide >= _rides.length) {
      _selectedRide = 0;
    }
  }

  Position _pickBetterPosition(Position? current, Position candidate) {
    if (current == null) return candidate;
    return candidate.accuracy < current.accuracy ? candidate : current;
  }

  bool _isPositionReliable(Position position) {
    final age = DateTime.now().difference(position.timestamp);
    final freshEnough = age.inMinutes <= 3;
    final preciseEnough = position.accuracy <= 35;
    return freshEnough && preciseEnough;
  }

  void _startLiveLocationUpdates() {
    _liveLocationTimer?.cancel();
    _livePositionSub?.cancel();

    // Use real-time GPS position stream for instant blue-dot tracking
    _livePositionSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 3,
          ),
        ).listen((position) {
          if (!mounted) return;

          final live = LatLng(position.latitude, position.longitude);
          // Always keep _currentPosition fresh for blue dot
          _currentPosition = live;

          if (_hasPreparedRoute && _dropoffPosition != null) return;
          // Skip pickup marker updates during active ride stages
          if (_stage == RideStage.confirmPickup ||
              _stage == RideStage.payment ||
              _stage == RideStage.matching ||
              _stage == RideStage.riding) {
            return;
          }

          final currentPickup = _currentPosition;
          if (currentPickup != null) {
            final movedMeters = Geolocator.distanceBetween(
              currentPickup.latitude,
              currentPickup.longitude,
              live.latitude,
              live.longitude,
            );
            if (movedMeters < 3) return;
          }

          if (_stage != RideStage.pin && _stage != RideStage.plan) return;

          _setState(() {
            _cameraTarget = live;
            _setPickupAnnotation(live);
            _tripMiles = '-- mi';
            _tripDuration = '-- min';
            _clearRouteAnnotation();
            _hasPreparedRoute = false;
          });

          _centerMapOn(live, zoom: _defaultMapZoom);

          final lastAddressTarget = _lastLiveAddressTarget;
          if (lastAddressTarget != null) {
            final addressMoved = Geolocator.distanceBetween(
              lastAddressTarget.latitude,
              lastAddressTarget.longitude,
              live.latitude,
              live.longitude,
            );
            if (addressMoved < 20) return;
          }

          _lastLiveAddressTarget = live;
          _refreshPickupAddress(live);
        });
  }

  void _setDefaultBirminghamPickup() {
    _setInitialPickup(_birminghamDefault, 'Birmingham, AL');
  }

  void _setInitialPickup(LatLng latLng, String initialAddress) {
    if (!mounted) return;

    _setState(() {
      _currentPosition = latLng;
      _cameraTarget = latLng;
      _pickupAddress = initialAddress;
      _pickupCtrl.text = initialAddress;
    });
  }

  String _coordinatesLabel(LatLng point) {
    return '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}';
  }

  void _onAddressChanged(String value, {required bool pickup}) {
    _searchDebounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      _setState(() {
        _isSearching = false;
        _searchError = null;
        _suggestions = [];
      });
      return;
    }

    final debounceMs = kIsWeb ? 250 : 200;
    _searchDebounce = Timer(Duration(milliseconds: debounceMs), () async {
      if (!mounted) return;
      _setState(() {
        _isSearching = true;
        _searchingPickup = pickup;
        _searchError = null;
      });

      try {
        final origin = _currentPosition;
        final raw = await _places.autocomplete(
          query,
          latitude: origin?.latitude,
          longitude: origin?.longitude,
        );
        final topSuggestions = raw.take(25).toList();
        final enriched = !pickup
            ? await _enrichSuggestionsWithDistance(topSuggestions)
            : topSuggestions;
        if (!mounted) return;

        _setState(() {
          _isSearching = false;
          _suggestions = enriched;
        });
      } catch (error) {
        if (!mounted) return;
        try {
          final origin = _currentPosition;
          final exact = await _places.geocodeAddress(
            query,
            latitude: origin?.latitude,
            longitude: origin?.longitude,
          );
          if (!mounted || exact == null) return;

          final position = LatLng(exact.lat, exact.lng);
          _currentPosition = position;
          _setPickupAnnotation(position);
          _setState(() {
            _pickupAddress = exact.address.isEmpty ? query : exact.address;
            _pickupCtrl.text = _pickupAddress;
            _hasPreparedRoute = false;
          });
        } catch (_) {}

        _setState(() {
          _isSearching = false;
          _suggestions = [];
          _searchError = null;
        });
      }
    });
  }

  Future<List<PlaceSuggestion>> _enrichSuggestionsWithDistance(
    List<PlaceSuggestion> input,
  ) async {
    final origin = _currentPosition;
    if (origin == null) return input;

    // Fast path: compute straight-line distance for items that already have coords
    // Skip expensive details() + matrix API calls — use haversine estimate instead
    final enriched = input.map((item) {
      if (item.lat != null && item.lng != null) {
        final meters = Geolocator.distanceBetween(
          origin.latitude,
          origin.longitude,
          item.lat!,
          item.lng!,
        );
        final miles = meters / 1609.344;
        final etaMinutes = ((miles / 25.0) * 60).ceil(); // ~25mph avg estimate
        return item.copyWith(distanceMiles: miles, etaText: '$etaMinutes min');
      }
      return item;
    }).toList();

    return enriched;
  }

  String _etaFromMiles(double? miles) {
    if (miles == null) return '-- min';
    final minutes = ((miles / 22.0) * 60).ceil();
    return '$minutes min';
  }

  Future<void> _selectSuggestion(
    PlaceSuggestion suggestion, {
    required bool pickup,
  }) async {
    // Immediately dismiss suggestions for snappy feel
    _setState(() {
      _suggestions = [];
      _searchError = null;
      _isSearching = false;
      // Show the suggestion description immediately as preview
      if (pickup) {
        _pickupCtrl.text = suggestion.description;
      } else {
        _dropoffCtrl.text = suggestion.description;
      }
    });

    PlaceDetails? details;
    if (suggestion.lat != null && suggestion.lng != null) {
      details = PlaceDetails(
        address: suggestion.description,
        lat: suggestion.lat!,
        lng: suggestion.lng!,
      );
    }
    details ??= await _places.details(suggestion.placeId);
    if (details == null || !mounted) return;

    if (!_isValidCoordinate(details.lat, details.lng)) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(S.of(context).invalidCoordinatesError),
          duration: const Duration(milliseconds: 1600),
        ),
      );
      return;
    }

    // Use formatted_address from Google (precise street address like Shopify widget)
    String resolvedAddress = details.address.trim();
    if (resolvedAddress.isEmpty) {
      // Fall back to reverse geocode to get precise address
      try {
        final reverse = await _places.reverseGeocode(
          lat: details.lat,
          lng: details.lng,
        );
        if (reverse != null && reverse.trim().isNotEmpty) {
          resolvedAddress = reverse.trim();
        }
      } catch (_) {}
    }
    if (resolvedAddress.isEmpty) {
      resolvedAddress = suggestion.description.trim();
    }

    final pos = LatLng(details.lat, details.lng);

    if (pickup) {
      _currentPosition = pos;
      _setPickupAnnotation(pos);
    } else {
      _dropoffPosition = pos;
      _setDropoffAnnotation(pos);
    }
    _setState(() {
      if (pickup) {
        _pickupAddress = resolvedAddress;
        _pickupCtrl.text = resolvedAddress;
      } else {
        _dropoffAddress = resolvedAddress;
        _dropoffCtrl.text = resolvedAddress;
      }
      _hasPreparedRoute = false;
    });

    await _animateCameraToSelection(pos);

    if (_currentPosition != null && _dropoffPosition != null) {
      if (_stage == RideStage.plan) {
        await _autoAdvanceToOptions();
      } else {
        await _prepareRoutePreview();
      }
    } else {
      if (!mounted) return;
      _setState(() {
        _tripMiles = '-- mi';
        _tripDuration = '-- min';
        _clearRouteAnnotation();
      });
    }
  }

  bool _isValidCoordinate(double lat, double lng) {
    if (lat.isNaN || lng.isNaN) return false;
    if (!lat.isFinite || !lng.isFinite) return false;
    if (lat < -90 || lat > 90) return false;
    if (lng < -180 || lng > 180) return false;
    return true;
  }

  Future<bool> _prepareRoutePreview({bool returnToPin = true}) async {
    if (_currentPosition == null || _dropoffPosition == null) return false;

    final animationTicket = ++_routeAnimationTicket;

    final origin = _currentPosition!;
    final destination = _dropoffPosition!;
    final route = await _directions.getRoute(
      origin: origin,
      destination: destination,
    );

    if (!mounted) return false;

    if (route != null) {
      // Cap route endpoints to exact pin coordinates
      final cappedPts = List<LatLng>.from(route.points);
      if (cappedPts.length >= 2) {
        cappedPts[0] = origin;
        cappedPts[cappedPts.length - 1] = destination;
      }
      _activeRoutePoints = cappedPts;
      _setState(() {
        _tripMiles = _formatMiles(route.distanceMeters);
        _tripDuration = route.durationText;
        _updateRidePricingFromDuration(_tripDuration);
        if (_pickupAddress.isEmpty) _pickupAddress = route.startAddress;
        _dropoffAddress = route.endAddress.isEmpty
            ? _dropoffAddress
            : route.endAddress;
        _dropoffCtrl.text = _dropoffAddress;
        _hasPreparedRoute = true;
        _clearRouteAnnotation();
      });

      await _startCinematicRouteReveal(cappedPts, animationTicket);
    } else {
      _activeRoutePoints = [];
      DistanceEstimate? estimate;
      try {
        final matrix = await _directions.getDistanceEstimates(
          origin: origin,
          destinations: [destination],
        );
        final key =
            '${destination.latitude.toStringAsFixed(6)},${destination.longitude.toStringAsFixed(6)}';
        estimate = matrix[key];
      } catch (_) {}

      if (!mounted) return false;
      _setState(() {
        _tripMiles = estimate == null
            ? '-- mi'
            : '${estimate.miles.toStringAsFixed(2)} mi';
        _tripDuration = estimate?.durationText ?? '-- min';
        _updateRidePricingFromDuration(_tripDuration);
        _hasPreparedRoute = false;
        _clearRouteAnnotation();
      });

      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(S.of(context).routeNotFoundError),
          duration: const Duration(milliseconds: 1800),
        ),
      );
      return false;
    }

    await _fitMapToRoute();

    if (!mounted) return false;
    FocusScope.of(context).unfocus();
    if (returnToPin) {
      _setStage(RideStage.plan);
    }
    return true;
  }

  String _formatMiles(int meters) {
    final miles = meters / 1609.344;
    return '${miles.toStringAsFixed(2)} mi';
  }

  void _setStage(RideStage stage) {
    _setState(() {
      _stage = stage;
      _panelDragHeight = null;
      _isPanelDragging = false;
      if (stage == RideStage.options) {
        _optionsExpanded = true;
      }
      if (stage != RideStage.plan) {
        _planBodyVisible = false;
      }
      // Refresh pickup annotation for current stage
      if (_currentPosition != null) _setPickupAnnotation(_currentPosition!);
    });

    if (stage == RideStage.plan) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _stage != RideStage.plan) return;
        _setState(() {
          _planBodyVisible = true;
        });
      });
    }

    // Start/stop glow animation based on stage
    if (stage == RideStage.options ||
        stage == RideStage.confirmPickup ||
        stage == RideStage.payment ||
        stage == RideStage.matching ||
        stage == RideStage.riding) {
      _startRouteGlowAnimation();
    } else {
      _stopRouteGlowAnimation();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Small delay so panel animation settles before camera moves
      await Future.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      // Only fit map when route is visible and it's a stage that should show the full route
      if (_currentPosition != null &&
          _dropoffPosition != null &&
          (stage == RideStage.options ||
              stage == RideStage.matching ||
              stage == RideStage.riding ||
              stage == RideStage.payment)) {
        if (stage == RideStage.matching) {
          // Moderate overview: center on midpoint so user sees the distance
          // without the map being too zoomed-in or fully fitted.
          _isCenteredOnPickup =
              false; // first compass tap will center on pickup
          final p = _currentPosition!;
          final d = _dropoffPosition!;
          final mid = LatLng(
            (p.latitude + d.latitude) / 2,
            (p.longitude + d.longitude) / 2,
          );
          // Pick a zoom that keeps both points roughly visible
          final latSpan = (p.latitude - d.latitude).abs();
          final lngSpan = (p.longitude - d.longitude).abs();
          final maxSpan = math.max(latSpan, lngSpan);
          // log2(180/span) gives a rough zoom for the span; pull back 0.6
          final zoom = maxSpan > 0
              ? ((math.log(180.0 / maxSpan) / math.ln2) - 0.6).clamp(10.0, 14.5)
              : 13.0;
          await _centerMapOn(mid, zoom: zoom);
        } else {
          await _fitMapToRoute();
        }
      }
    });
  }

  void _clearAddressInput({required bool pickup}) {
    _searchDebounce?.cancel();

    _setState(() {
      if (pickup) {
        _pickupCtrl.clear();
      } else {
        _dropoffCtrl.clear();
        _dropoffAddress = '';
        _dropoffPosition = null;
        _tripMiles = '-- mi';
        _tripDuration = '-- min';
        _clearRouteAnnotation();
      }

      _suggestions = [];
      _searchError = null;
      _isSearching = false;
      _hasPreparedRoute = false;
    });
  }

  void _startRideProgressTracking() {
    var tripStartedNotified = false;
    var arrivedNotified = false;
    var fsSyncedArrived = false;
    var fsSyncedInTrip = false;
    _rideLifecycleTimer?.cancel();
    _rideLifecycleTimer = Timer.periodic(const Duration(milliseconds: 750), (
      timer,
    ) async {
      if (!mounted || _stage != RideStage.riding) {
        timer.cancel();
        return;
      }

      // Poll real status + driver position from backend
      if (_currentTripId != null) {
        try {
          final trip = await ApiService.getTrip(_currentTripId!);
          final status = trip['status']?.toString() ?? '';

          // Extract real driver GPS position
          final dLat = (trip['driver_lat'] as num?)?.toDouble();
          final dLng = (trip['driver_lng'] as num?)?.toDouble();
          if (dLat != null && dLng != null) {
            final newPos = LatLng(dLat, dLng);
            // Only animate if driver actually moved (>2m)
            final moved = _driverPosition != null
                ? Geolocator.distanceBetween(
                    _driverPosition!.latitude,
                    _driverPosition!.longitude,
                    newPos.latitude,
                    newPos.longitude,
                  )
                : 999.0;
            if (moved > 2) {
              _animateDriverTo(newPos);
            }
          }

          if (status == 'completed') {
            timer.cancel();
            // â”€â”€ Sync completed to Firestore for Dispatch Admin â”€â”€
            if (_firestoreTripId != null) {
              TripFirestoreService.syncTripCompleted(_firestoreTripId!);
            }
            final cmpTitle = mounted ? S.of(context).tripCompletedTitle : '';
            final cmpMsg = mounted ? S.of(context).arrivedAtDestination : '';
            await LocalDataService.addNotification(
              title: cmpTitle,
              message: cmpMsg,
              type: 'ride',
            );
            // â”€â”€ Show payment confirmation â”€â”€
            if (mounted) {
              final payStatus = trip['payment_status']?.toString() ?? 'unpaid';
              final fare = (trip['fare'] as num?)?.toDouble() ?? 0.0;
              final fareStr = fare > 0 ? '\$${fare.toStringAsFixed(2)}' : '';
              String payMsg;
              Color payColor;
              if (payStatus == 'paid') {
                payMsg = fareStr.isNotEmpty
                    ? '✓ Payment of $fareStr processed'
                    : '✓ Payment processed';
                payColor = const Color(0xFF4CAF50);
              } else if (payStatus == 'failed') {
                payMsg = 'Payment could not be processed. Please update your payment method.';
                payColor = const Color(0xFFF44336);
              } else {
                payMsg = fareStr.isNotEmpty ? 'Trip fare: $fareStr' : 'Trip completed';
                payColor = const Color(0xFFE8C547);
              }
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(payMsg, style: const TextStyle(fontWeight: FontWeight.w600)),
                  backgroundColor: payColor,
                  duration: const Duration(seconds: 5),
                ),
              );
            }
            _completeRide();
            return;
          } else if (status == 'in_trip') {
            if (!tripStartedNotified) {
              tripStartedNotified = true;
              // â”€â”€ Sync in_progress to Firestore for Dispatch Admin â”€â”€
              if (_firestoreTripId != null && !fsSyncedInTrip) {
                fsSyncedInTrip = true;
                TripFirestoreService.syncTripStarted(_firestoreTripId!);
              }
              if (mounted) { LocalDataService.addNotification(
                title: S.of(context).tripStartedTitle,
                message: S.of(context).headingToDestination(_dropoffAddress),
                type: 'ride',
              ); }
            }
            final dropoffPos = _dropoffPosition;
            if (mounted) {
              // Calculate progress based on driver distance to dropoff
              double progress = 0;
              if (dropoffPos != null && _driverPosition != null) {
                final pickupPos = _currentPosition;
                if (pickupPos != null) {
                  final totalDist = Geolocator.distanceBetween(
                    pickupPos.latitude,
                    pickupPos.longitude,
                    dropoffPos.latitude,
                    dropoffPos.longitude,
                  );
                  final remaining = Geolocator.distanceBetween(
                    _driverPosition!.latitude,
                    _driverPosition!.longitude,
                    dropoffPos.latitude,
                    dropoffPos.longitude,
                  );
                  progress = totalDist > 0
                      ? (1.0 - remaining / totalDist).clamp(0.0, 1.0)
                      : 0.0;
                }
                // Calculate real ETA
                final distKm =
                    Geolocator.distanceBetween(
                      _driverPosition!.latitude,
                      _driverPosition!.longitude,
                      dropoffPos.latitude,
                      dropoffPos.longitude,
                    ) /
                    1000;
                final etaMin = (distKm * 1000 / 17.88 / 60).ceil().clamp(1, 99);
                _setState(() {
                  _tripStatus = 'in_trip';
                  _rideProgress = progress;
                  _driverEta = '$etaMin min';
                });
              } else {
                _setState(() => _tripStatus = 'in_trip');
              }
            }
            // 3D Chase-cam follows driver every frame via _onDriverMotionTick
            // Only set fallback camera here if SmoothMotion is not active
            if (_driverPosition != null &&
                mounted &&
                _driverMotion == null) {
              // Calculate bearing from driver to dropoff
              double tripBearing = _driverBearing;
              if (tripBearing == 0 && dropoffPos != null) {
                final dLng =
                    (dropoffPos.longitude - _driverPosition!.longitude) *
                    math.pi /
                    180;
                final aLat = _driverPosition!.latitude * math.pi / 180;
                final bLat = dropoffPos.latitude * math.pi / 180;
                final x = math.sin(dLng) * math.cos(bLat);
                final y =
                    math.cos(aLat) * math.sin(bLat) -
                    math.sin(aLat) * math.cos(bLat) * math.cos(dLng);
                tripBearing = (math.atan2(x, y) * 180 / math.pi + 360) % 360;
              }
              _panTo(
                _driverPosition!,
                zoom: 18.5,
                bearing: tripBearing,
                tilt: 0,
              );
            }
            // Draw/update route from driver â†’ dropoff
            await _updateDriverRoute(status);
          } else if (status == 'arrived') {
            if (!arrivedNotified) {
              arrivedNotified = true;
              // â”€â”€ Sync driver_arrived to Firestore for Dispatch Admin â”€â”€
              if (_firestoreTripId != null && !fsSyncedArrived) {
                fsSyncedArrived = true;
                TripFirestoreService.syncDriverArrived(_firestoreTripId!);
              }
              if (mounted) { LocalDataService.addNotification(
                title: S.of(context).driverArrivedTitle,
                message: S.of(context).driverArrivedMessage(nh.displayName(_driverName, _driverCar)),
                type: 'ride',
              ); }
            }
            if (mounted) {
              _setState(() {
                _driverEta = 'Arrived';
                _tripStatus = 'arrived';
              });
            }
            await _updateDriverRoute(status);
          } else if (status == 'driver_en_route' ||
              status == 'driver_assigned') {
            final pickupPos = _currentPosition;
            if (mounted) {
              // Calculate ETA to pickup
              if (pickupPos != null && _driverPosition != null) {
                final distKm =
                    Geolocator.distanceBetween(
                      _driverPosition!.latitude,
                      _driverPosition!.longitude,
                      pickupPos.latitude,
                      pickupPos.longitude,
                    ) /
                    1000;
                final etaMin = (distKm * 1000 / 17.88 / 60).ceil().clamp(1, 99);
                _setState(() {
                  _tripStatus = status;
                  _driverEta = '$etaMin min';
                });
              } else {
                _setState(() => _tripStatus = status);
              }
            }
            // 3D Chase-cam follows driver on map during en route
            if (_driverPosition != null &&
                mounted &&
                _driverMotion == null) {
              // Calculate bearing from driver to pickup
              double pickupBearing = _driverBearing;
              if (pickupBearing == 0 && pickupPos != null) {
                final dLng =
                    (pickupPos.longitude - _driverPosition!.longitude) *
                    math.pi /
                    180;
                final aLat = _driverPosition!.latitude * math.pi / 180;
                final bLat = pickupPos.latitude * math.pi / 180;
                final x = math.sin(dLng) * math.cos(bLat);
                final y =
                    math.cos(aLat) * math.sin(bLat) -
                    math.sin(aLat) * math.cos(bLat) * math.cos(dLng);
                pickupBearing = (math.atan2(x, y) * 180 / math.pi + 360) % 360;
              }
              _panTo(
                _driverPosition!,
                zoom: 18.5,
                bearing: pickupBearing,
                tilt: 0,
              );
            }
            // Draw/update route from driver â†’ pickup
            await _updateDriverRoute(status);
          } else if (status == 'canceled' || status == 'cancelled') {
            timer.cancel();
            _rideLifecycleTimer?.cancel();
            final reason =
                (trip['cancel_reason'] ??
                        trip['cancellation_reason'] ??
                        trip['reason'] ??
                        '')
                    .toString()
                    .toLowerCase();
            final isNoDrivers =
                reason.contains('no_driver') ||
                reason.contains('no driver') ||
                reason.contains('timeout') ||
                reason.contains('expired') ||
                reason.isEmpty;
            if (_firestoreTripId != null) {
              TripFirestoreService.syncTripCancelled(
                _firestoreTripId!,
                reason: isNoDrivers
                    ? 'No drivers available'
                    : 'Cancelled by dispatch',
              );
            }
            if (mounted) {
              _setState(() {
                _rideProgress = 0;
                _clearRouteAnnotation();
                _activeRoutePoints = [];
                _driverRoutePoints = [];
                // driver annotation cleared via manager
                _dropoffPosition = null;
              });
              if (isNoDrivers) {
                _setStage(RideStage.options);
              } else {
                _setStage(RideStage.plan);
                _showTripCancelledDialog();
              }
            }
            return;
          }
          if (_driverPosition != null) _animateDriverTo(_driverPosition!);
        } catch (e) {
          debugPrint('âš ï¸ Ride tracking: $e');
        }
      }
    });
  }

  /// Trim the rider-side route behind the driver marker (Google Maps style)
  void _trimRiderRoute(LatLng driverPos) {
    if (_driverRoutePoints.length < 3) return;
    int closestIdx = 0;
    double closestDist = double.infinity;
    for (int i = 0; i < _driverRoutePoints.length; i++) {
      final d = Geolocator.distanceBetween(
        driverPos.latitude,
        driverPos.longitude,
        _driverRoutePoints[i].latitude,
        _driverRoutePoints[i].longitude,
      );
      if (d < closestDist) {
        closestDist = d;
        closestIdx = i;
      }
    }
    if (closestIdx > 0) {
      _driverRoutePoints = _driverRoutePoints.sublist(closestIdx);
    }
    if (_driverRoutePoints.isNotEmpty) {
      _driverRoutePoints[0] = driverPos;
    }
    // Rebuild annotation with trimmed points
    if (_driverRoutePoints.length >= 2) {
      _setRouteAnnotation(List.from(_driverRoutePoints));
    }
  }

  /// Decode an encoded polyline string into a list of LatLng points.
  List<LatLng> _decodePolyline(String enc) {
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

  double _calcBearing(LatLng a, LatLng b) {
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final aLat = a.latitude * math.pi / 180;
    final bLat = b.latitude * math.pi / 180;
    final x = math.sin(dLng) * math.cos(bLat);
    final y =
        math.cos(aLat) * math.sin(bLat) -
        math.sin(aLat) * math.cos(bLat) * math.cos(dLng);
    return (math.atan2(x, y) * 180 / math.pi + 360) % 360;
  }

  /// Smooth heading interpolation (avoids 360→0 jumps)
  double _lerpAngle(double from, double to, double t) {
    double diff = (to - from) % 360;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    return (from + diff * t) % 360;
  }

  void _showDriverNoteSheet() {
    final noteCtrl = TextEditingController(text: _driverNote);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: SafeArea(
            top: false,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: _c.mapPanel,
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    S.of(context).noteForDriver,
                    style: TextStyle(
                      color: _c.textPrimary,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteCtrl,
                    autofocus: true,
                    maxLines: 3,
                    style: TextStyle(color: _c.textPrimary, fontSize: 16),
                    decoration: InputDecoration(
                      hintText: S.of(context).noteHint,
                      hintStyle: TextStyle(color: _c.textTertiary),
                      filled: true,
                      fillColor: _c.mapSurface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: _panelBlack,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      onPressed: () {
                        _setState(() => _driverNote = noteCtrl.text.trim());
                        Navigator.of(context).pop();
                      },
                      child: Text(
                        S.of(context).saveButton,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _capitalizedBrand(String? brand) {
    switch (brand) {
      case 'visa':
        return 'Visa';
      case 'mastercard':
        return 'Mastercard';
      case 'amex':
        return 'Amex';
      case 'discover':
        return 'Discover';
      case 'diners':
        return 'Diners Club';
      case 'jcb':
        return 'JCB';
      default:
        return 'Card';
    }
  }
}
