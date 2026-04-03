part of 'ride_request_screen.dart';

// ════════════════════════════════════════════════════════════
//  CONTROLLER — payment, search, scheduling
// ════════════════════════════════════════════════════════════

extension _RideRequestController on _RideRequestScreenState {

  Future<void> _loadPinIcon() async {
    _goldPinIcon = await renderCircularPinBytes(
      icon: CircularPinIcon.person,
      isPickup: true,
      radius: 36,
    );
    _goldDropoffPinIcon = await renderCircularPinBytes(
      icon: CircularPinIcon.home,
      isPickup: false,
      radius: 36,
    );
    if (mounted) _setState(() {});
  }

  Future<Uint8List?> _buildGoldPinBytes() async {
    return renderCircularPinBytes(
      icon: CircularPinIcon.person,
      isPickup: true,
      radius: 36,
    );
  }

  /// Geocode the airport name + terminal + zone into real coordinates,
  /// then auto-fill the pickup field so the rider sees the exact address.
  Future<void> _autoSetAirportPickup(AirportSelection sel) async {
    final places = PlacesService(ApiKeys.webServices);
    final ap = sel.airport;
    // Build a descriptive search query that includes terminal & zone
    final terminalPart = sel.terminal != null ? ', ${sel.terminal}' : '';
    final zonePart = sel.pickupZone != null ? ' — ${sel.pickupZone}' : '';
    final query = '${ap.name}$terminalPart';

    try {
      // Search via Places autocomplete
      final results = await places.autocomplete(query);
      if (!mounted) return;
      if (results.isNotEmpty) {
        final first = results.first;
        final details = await places.details(first.placeId);
        if (!mounted) return;
        if (details != null) {
          // Build the display label: "Terminal S — Arrivals Level 1 - Door 5"
          final label = '${ap.code} · ${sel.terminal ?? ap.name}$zonePart';
          _ctrl.setPickup(details, label);
          // Animate map camera to airport
          final target = LatLng(details.lat, details.lng);
          _mapCtrl?.flyTo(
            mapbox.CameraOptions(center: mapbox.Point(coordinates: mapbox.Position(target.longitude, target.latitude)), zoom: 17.0),
            mapbox.MapAnimationOptions(duration: 800),
          );
          return;
        }
      }
    } catch (_) {}

    // Fallback: use airport name as manual label with no coords
    // (rider must confirm/adjust pickup on map)
    final terminalLabel = sel.terminal != null
        ? '${ap.code} · ${sel.terminal}$zonePart'
        : ap.name;
    // Try a direct text search as second fallback
    try {
      final results = await places.autocomplete(ap.name);
      if (!mounted) return;
      if (results.isNotEmpty) {
        final details = await places.details(results.first.placeId);
        if (!mounted || details == null) return;
        _ctrl.setPickup(details, terminalLabel);
      }
    } catch (_) {}
  }

  /// Auto-geocode a dropoff address string (from Quick Access) and set it.
  Future<void> _autoSetDropoff(String address) async {
    final places = PlacesService(ApiKeys.webServices);
    try {
      final results = await places.autocomplete(address);
      if (!mounted || results.isEmpty) return;
      final details = await places.details(results.first.placeId);
      if (!mounted || details == null) return;

      // Use current location as pickup if available
      if (_userLocation != null) {
        final curLabel = _currentAddress.isNotEmpty ? _currentAddress : 'current location';
        _ctrl.setPickup(
          PlaceDetails(
            address: curLabel,
            lat: _userLocation!.latitude,
            lng: _userLocation!.longitude,
          ),
          curLabel,
        );
      }
      _ctrl.setDropoff(details, address);
    } catch (_) {}
  }

  Future<void> _loadLinkedPayments() async {
    final linked = await LocalDataService.getLinkedPaymentMethods();
    final last4 = await LocalDataService.getCreditCardLast4();
    final brand = await LocalDataService.getCreditCardBrand();
    if (!mounted) return;
    _setState(() {
      _linkedPaymentMethods = linked;
      _savedCardLast4 = last4;
      _savedCardBrand = brand;
    });
  }

  // ── Location ──

  Future<void> _initLocation() async {
    try {
      bool svc = await Geolocator.isLocationServiceEnabled();
      if (!svc) {
        _setState(() => _fetchingLocation = false);
        return;
      }
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever) {
        if (mounted) {
          _setState(() => _fetchingLocation = false);
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(S.of(ctx).locationPermissionRequired),
              content: Text(S.of(ctx).locationPermissionPermanentlyDeniedMsg),
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
      if (perm == LocationPermission.denied) {
        _setState(() => _fetchingLocation = false);
        return;
      }

      // Fast path: use last known position immediately while waiting for fresh fix
      try {
        final lastPos = await Geolocator.getLastKnownPosition();
        if (lastPos != null && mounted) {
          final lastLl = LatLng(lastPos.latitude, lastPos.longitude);
          _setState(() {
            _userLocation = lastLl;
            _center = lastLl;
          });
          _mapCtrl?.setCamera(mapbox.CameraOptions(
            center: mapbox.Point(coordinates: mapbox.Position(lastLl.longitude, lastLl.latitude)),
            zoom: 15.5,
          ));
        }
      } catch (_) {}

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      if (!mounted) return;

      final ll = LatLng(pos.latitude, pos.longitude);
      _setState(() {
        _userLocation = ll;
        _center = ll;
        _fetchingLocation = false;
      });
      _mapCtrl?.flyTo(
        mapbox.CameraOptions(center: mapbox.Point(coordinates: mapbox.Position(ll.longitude, ll.latitude)), zoom: 15.5),
        mapbox.MapAnimationOptions(duration: 800),
      );

      // Reverse geocode for address
      final places = PlacesService(ApiKeys.webServices);
      final addr = await places.reverseGeocode(
        lat: pos.latitude,
        lng: pos.longitude,
      );
      if (addr != null && mounted) {
        _setState(() => _currentAddress = addr);
      }
    } catch (_) {
      if (mounted) _setState(() => _fetchingLocation = false);
    }
  }

  void _onStateChange() {
    if (!mounted) return;
    final s = _ctrl.state;

    switch (s.phase) {
      case RiderPhase.previewRoute:
      case RiderPhase.selectingRide:
        // Show bottom sheet immediately
        _sheetCtrl.forward();
        // Place markers immediately but only if real route isn't ready yet.
        // Once the real route arrives _drawRoute/_rebuildMarkers takes over —
        // running both concurrently creates duplicate orphaned pins.
        final hasRealRoute = s.route != null &&
            s.rideOptions.isNotEmpty &&
            s.route!.points.length > 15;
        if (s.pickup != null && s.dropoff != null && !hasRealRoute) {
          _placeMarkersOnly();
        }
        // Draw polyline + cinematic only when REAL route arrives (once).
        if (hasRealRoute) {
          _fetchingRoute = false;
          if (!_cinematicDone) {
            _drawRoute();
          }
        }
        // Mark options as loaded when rideOptions arrive
        if (s.rideOptions.isNotEmpty && !_optionsLoaded) {
          _shimmerTimeoutTimer?.cancel();
          _setState(() => _optionsLoaded = true);
        }
        // Auto-select ride option from home screen card tap
        if (!_didAutoSelectRide &&
            widget.initialRideId != null &&
            s.rideOptions.isNotEmpty) {
          _didAutoSelectRide = true;
          final match = s.rideOptions.cast<RideOption?>().firstWhere(
            (o) => o!.id == widget.initialRideId,
            orElse: () => null,
          );
          if (match != null) {
            _ctrl.selectRideOption(match);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _setState(() => _rideOptionsExpanded = false);
            });
          }
        }
        break;
      case RiderPhase.requesting:
      case RiderPhase.searchingDriver:
        // Show map with bottom card immediately — no splash
        if (!_searchingShowMap) {
          _searchMapTimer?.cancel();
          _searchingSplash = false;
          _searchingShowMap = true;
          // Start cycling status messages
          _searchStatusIdx = 0;
          _searchElapsedSec = 0;
          _searchStatusTimer?.cancel();
          _searchStatusTimer = Timer.periodic(const Duration(seconds: 10), (_) {
            if (mounted) {
              _setState(() => _searchStatusIdx++);
              _animateSearchCameraToAngle(_searchStatusIdx);
            }
          });
          _searchElapsedTimer?.cancel();
          _searchElapsedTimer = Timer.periodic(const Duration(seconds: 2), (_) {
            if (mounted) _setState(() => _searchElapsedSec += 2);
          });
          // Trigger cinematic sequence on searching phase open
          _replayCinematicIfRouteAvailable();
        }
        break;
      case RiderPhase.driverAssigned:
        // Show premium "Driver Found" overlay, then auto-navigate after 4s
        if (!_driverFoundVisible && !_navigatingToTracking) {
          _driverFoundVisible = true;
          HapticFeedback.heavyImpact();

          // Init animation controllers
          _dfCheckCtrl?.dispose();
          _dfCheckCtrl = AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 900),
          )..forward();
          _dfStaggerCtrl?.dispose();
          _dfStaggerCtrl = AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 1400),
          )..forward();
          _dfShimmerCtrl?.dispose();
          _dfShimmerCtrl = AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 2000),
          )..repeat();
          // Map tilt: 0° → 20° over 1s
          _dfTiltCtrl?.dispose();
          _dfTiltCtrl = AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 1000),
          );
          _dfTiltAnim = Tween<double>(begin: 0.0, end: 20.0).animate(
            CurvedAnimation(parent: _dfTiltCtrl!, curve: Curves.easeInOutCubic),
          );
          _dfMsgIndex = 0;
          _dfMsgTimer?.cancel();
          _dfMsgTimer = Timer.periodic(
            const Duration(milliseconds: 2500),
            (_) {
              if (mounted) _setState(() => _dfMsgIndex = (_dfMsgIndex + 1) % 3);
            },
          );

          _driverFoundTimer?.cancel();
          _driverFoundTimer = Timer(const Duration(milliseconds: 2000), () {
            if (!mounted) return;
            _ctrl.transitionToArriving();
          });
        }
        break;
      case RiderPhase.driverArriving:
        if (!_navigatingToTracking) {
          _navigatingToTracking = true;
          _driverFoundVisible = false;
          _driverFoundTimer?.cancel();
          _goToTracking();
        }
        break;
      case RiderPhase.cancelled:
        _searchingShowMap = false;
        _searchingSplash = false;
        _searchMapTimer?.cancel();
        _searchMapTimer = null;
        _splashTimer?.cancel();
        _splashTimer = null;
        // Clean up route/pins immediately on cancellation
        _cleanupMapAnnotations();
        // Rider already confirmed cancellation — just go home, no extra dialog
        if (_riderInitiatedCancel) {
          _riderInitiatedCancel = false;
          _ctrl.reset();
          Navigator.of(context).popUntil((route) => route.isFirst);
          break;
        }
        // Only show cancel dialog if there's a specific cancel reason from dispatch
        // (not just "no drivers available" which is automatic)
        if (s.cancelReason != null && s.cancelReason!.isNotEmpty) {
          final reason = s.cancelReason!;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (_) => AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                title: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.orange, size: 28),
                    SizedBox(width: 10),
                    Text(S.of(context).tripCancelled),
                  ],
                ),
                content: Text(reason, style: const TextStyle(fontSize: 15)),
                actions: [
                  TextButton(
                    onPressed: () {
                      _ctrl.reset();
                      // Pop dialog + ride request screen → back to homescreen
                      Navigator.of(context).popUntil((route) => route.isFirst);
                    },
                    child: Text(S.of(context).okBtn),
                  ),
                ],
              ),
            );
          });
        } else {
          // Fallback: show a generic cancellation message instead of silently resetting
          final fallbackReason = S.of(context).tripCancelled;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (_) => AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                title: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.orange, size: 28),
                    SizedBox(width: 10),
                    Text(S.of(context).tripCancelled),
                  ],
                ),
                content: Text(fallbackReason, style: const TextStyle(fontSize: 15)),
                actions: [
                  TextButton(
                    onPressed: () {
                      _ctrl.reset();
                      // Pop dialog + ride request screen → back to homescreen
                      Navigator.of(context).popUntil((route) => route.isFirst);
                    },
                    child: Text(S.of(context).okBtn),
                  ),
                ],
              ),
            );
          });
        }
        break;
      default:
        _fetchingRoute = false;
        _searchingShowMap = false;
        _searchingSplash = false;
        _searchMapTimer?.cancel();
        _searchMapTimer = null;
        _splashTimer?.cancel();
        _splashTimer = null;
        break;
    }
    _setState(() {});
  }

  // ── Search screen ──

  Future<void> _openSearch() async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      scaleExpandRoute(
        PickupDropoffSearchScreen(
          initialPickupText: _currentAddress,
          initialPickupLat: _userLocation?.latitude,
          initialPickupLng: _userLocation?.longitude,
        ),
      ),
    );

    if (result == null || !mounted) return;

    final pickupDetails = result['pickup'] as PlaceDetails?;
    final dropoffDetails = result['dropoff'] as PlaceDetails?;
    final pickupLabel = result['pickupLabel'] as String? ?? '';
    final dropoffLabel = result['dropoffLabel'] as String? ?? '';

    // Ensure loading overlay is up (already set by onWillReturn, but guard here too)
    if (!_fetchingRoute) _setState(() => _fetchingRoute = true);

    if (pickupDetails != null) {
      _ctrl.setPickup(pickupDetails, pickupLabel);
    } else if (_userLocation != null) {
      // Use current location as pickup (fallback to 'current location' so
      // the driver side can reverse-geocode when _currentAddress is still '')
      final curLabel = _currentAddress.isNotEmpty ? _currentAddress : 'current location';
      _ctrl.setPickup(
        PlaceDetails(
          address: curLabel,
          lat: _userLocation!.latitude,
          lng: _userLocation!.longitude,
        ),
        curLabel,
      );
    }

    if (dropoffDetails != null) {
      _ctrl.setDropoff(dropoffDetails, dropoffLabel);
    }
  }

  double _bottomSheetHeight(RiderPhase phase, double bottomPad) {
    switch (phase) {
      case RiderPhase.previewRoute:
      case RiderPhase.selectingRide:
        final screenH = MediaQuery.of(context).size.height;
        final h = (screenH * 0.45).clamp(280.0, 420.0);
        return h + bottomPad;
      case RiderPhase.requesting:
      case RiderPhase.searchingDriver:
        return 180 + bottomPad;
      default:
        return 0;
    }
  }

  /// Truncate address to roughly the first half (cut at nearest space/comma).
  String _truncateHalf(String s) {
    if (s.length <= 20) return s;
    final half = (s.length * 0.5).round();
    // cut at last separator within the first half
    int cut = half;
    for (int i = half; i >= 0; i--) {
      if (s[i] == ',' || s[i] == ' ') {
        cut = i;
        break;
      }
    }
    return '${s.substring(0, cut).trimRight()}…';
  }

  // ── Payment sheet ──────────────────────────────────────────

  void _showPaymentSheet(AppColors c, RideOption? option) {
    final price = option != null
        ? '\$${option.priceEstimate.toStringAsFixed(2)}'
        : '';

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
              decoration: const BoxDecoration(
                color: Color(0xFF1A1A1A),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Drag handle
                    Center(
                      child: Container(
                        width: 40,
                        height: 4.5,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(40),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      S.of(context).paymentLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Ride summary
                    if (option != null)
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          children: [
                            Builder(
                              builder: (_) {
                                final optName = (option.name).toLowerCase();
                                String asset = 'assets/images/car_economy.png';
                                if (optName.contains('suburban') || optName.contains('vip') || optName.contains('suv')) {
                                  asset = 'assets/images/car_suv.png';
                                } else if (optName.contains('camry') || optName.contains('premium') || optName.contains('sedan')) {
                                  asset = 'assets/images/car_sedan.png';
                                }
                                return Image.asset(
                                  asset,
                                  width: 40,
                                  height: 40,
                                  fit: BoxFit.contain,
                                  filterQuality: FilterQuality.high,
                                  isAntiAlias: true,
                                  cacheWidth: 256,
                                  errorBuilder: (_, __, ___) => Icon(
                                    Icons.directions_car_rounded,
                                    color: c.gold,
                                    size: 28,
                                  ),
                                );
                              },
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    option.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    _ctrl.state.route?.distanceText ?? '',
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.5,
                                      ),
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              price,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),

                    // Payment method selector — gray "Payment Method" button
                    GestureDetector(
                      onTap: () {
                        Navigator.pop(ctx);
                        _showPaymentMethodPicker(c, option);
                      },
                      child: Container(
                        width: double.infinity,
                        height: 52,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2A2A),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Payment Method',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.2,
                              ),
                            ),
                            SizedBox(width: 6),
                            Icon(
                              Icons.chevron_right,
                              color: Colors.white,
                              size: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Pay button — black with gold border, [logo] Pay · $X.XX
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: GestureDetector(
                        onTap: _isProcessingPayment
                            ? null
                            : () => _processPayment(
                                ctx,
                                c,
                                option,
                                setSheetState,
                              ),
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF0D0D0D),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: _isProcessingPayment
                                  ? const Color(0xFFFFD700).withValues(alpha: 0.3)
                                  : const Color(0xFFFFD700),
                              width: 1.5,
                            ),
                          ),
                          child: _isProcessingPayment
                              ? const Center(
                                  child: SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Colors.white70,
                                    ),
                                  ),
                                )
                              : Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      _buildPaymentLogo(),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Pay · $price',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Processes payment: verifies linked method, checks Stripe PM ID for cards,
  /// charges payment. If anything fails → shows Declined dialog, stays on sheet.
  /// In DEBUG mode, payment is always simulated successfully for testing.
  Future<void> _processPayment(
    BuildContext ctx,
    AppColors c,
    RideOption? option,
    void Function(void Function()) setSheetState,
  ) async {
    if (_rideFlowLocked || _isProcessingPayment) return;
    _rideFlowLocked = true;
    setSheetState(() => _isProcessingPayment = true);
    _setState(() => _isProcessingPayment = true);

    try {
      try {
        final success = await _confirmNativePayment(option);
        if (!mounted) return;
        if (!success) {
          setSheetState(() => _isProcessingPayment = false);
          _setState(() => _isProcessingPayment = false);
          return; // User cancelled — stay on sheet
        }
      } catch (e) {
        if (!mounted) return;
        setSheetState(() => _isProcessingPayment = false);
        _setState(() => _isProcessingPayment = false);
        debugPrint('Payment error: $e');
        Navigator.of(context).pop(); // close payment modal
        _setState(() => _showPaymentDeclinedBanner = true);
        return;
      }

      if (!mounted) return;
      setSheetState(() => _isProcessingPayment = false);
      _setState(() => _isProcessingPayment = false);
      Navigator.of(context).pop();
      if (widget.applyPromo) await LocalDataService.setPromoUsed();
      AnalyticsService.instance.logRideRequested(
        option?.name ?? 'unknown',
        option?.priceEstimate ?? 0,
      );

      if (_ctrl.state.scheduledAt != null) {
        await _createScheduledTrip();
        return;
      }
      _ctrl.setHeldPaymentIntentId(_heldPaymentIntentId);
      _ctrl.requestRide();
    } finally {
      _rideFlowLocked = false;
    }
  }

  /// Processes payment directly from the route preview sheet.
  Future<void> _startRideDirectly(AppColors c, RideOption? option) async {
    if (option == null) return;
    if (_rideFlowLocked || _isProcessingPayment) return;
    _rideFlowLocked = true;

    try {
      final nav = Navigator.of(context);

      // Native pay (Apple/Google Pay/PayPal): OS sheet must appear first.
      // Card / sandbox: payment runs inside the searching screen animation.
      final bool isNativePay = !AppConfig.sandboxPayments &&
          (_selectedPaymentMethod == 'apple_pay' ||
              _selectedPaymentMethod == 'google_pay' ||
              _selectedPaymentMethod == 'paypal');

      bool nativePayFailed = false;
      if (isNativePay) {
        _setState(() => _isProcessingPayment = true);
        try {
          final ok = await _confirmNativePayment(option);
          if (!mounted) return;
          if (!ok) {
            _setState(() => _isProcessingPayment = false);
            return; // user dismissed OS sheet — stay on screen
          }
        } catch (e) {
          if (!mounted) return;
          debugPrint('Native payment error: $e');
          nativePayFailed = true;
        }
        _setState(() => _isProcessingPayment = false);
      }

      if (!mounted) return;
      if (widget.applyPromo) await LocalDataService.setPromoUsed();
      AnalyticsService.instance.logRideRequested(option.name, option.priceEstimate);

      if (_ctrl.state.scheduledAt != null) {
        await _createScheduledTrip();
        return;
      }

      bool paymentDeclinedFlag = false;

      final cancelled = await nav.push<bool>(
        searchingDriverRoute(
          onCancel: _cancelSearching,
          paymentCallback: isNativePay ? null : () => _confirmNativePayment(option),
          initiallyDeclined: nativePayFailed,
          onPaymentDeclined: () => paymentDeclinedFlag = true,
        ),
      );

      if (cancelled == true) {
        // _onStateChange already handles popUntil on cancel — no extra pop needed
        return;
      }
      if (nativePayFailed || paymentDeclinedFlag) {
        if (mounted) _setState(() => _showPaymentDeclinedBanner = true);
        return;
      }
      if (!mounted) return;

      _ctrl.setHeldPaymentIntentId(_heldPaymentIntentId);
      _ctrl.requestRide();
    } finally {
      _rideFlowLocked = false;
    }
  }

  /// Triggers the native payment confirmation for the selected payment method.
  /// Returns true if payment was authorized, false if user cancelled.
  /// Throws on failure.
  Future<bool> _confirmNativePayment(RideOption? option) async {
    if (option == null) return false;
    final amountCents = (option.priceEstimate * 100).round();
    final label = 'Cruise · ${option.name}';

    // Sandbox mode: simulate successful payment with brief delay
    if (AppConfig.sandboxPayments) {
      await Future.delayed(const Duration(milliseconds: 800));
      return true;
    }

    switch (_selectedPaymentMethod) {
      case 'apple_pay':
        return _confirmApplePay(amountCents, label);
      case 'google_pay':
        return _confirmGooglePay(amountCents, label);
      case 'paypal':
        return _confirmPayPal(amountCents);
      case 'credit_card':
        return _confirmCard(amountCents);
      default:
        return true;
    }
  }

  /// Apple Pay: present native Apple Pay sheet via Stripe (hold only).
  Future<bool> _confirmApplePay(int amountCents, String label) async {
    // Check if Apple Pay is available on this device
    final supported = await stripe.Stripe.instance.isPlatformPaySupported(
      googlePay: const stripe.IsGooglePaySupportedParams(),
    );
    if (!supported) {
      debugPrint('[ApplePay] Not supported on this device');
      // Fall back to card payment sheet
      return _confirmCardSheet(amountCents, label);
    }

    try {
      final piResult = await ApiService.createPaymentIntent(amountCents: amountCents, holdOnly: true);
      final clientSecret = piResult['client_secret'] as String?;
      _heldPaymentIntentId = piResult['payment_intent_id'] as String?;
      if (clientSecret == null || clientSecret.startsWith('mock_')) return true;

      await stripe.Stripe.instance.confirmPlatformPayPaymentIntent(
        clientSecret: clientSecret,
        confirmParams: stripe.PlatformPayConfirmParams.applePay(
          applePay: stripe.ApplePayParams(
            cartItems: [
              stripe.ApplePayCartSummaryItem.immediate(
                label: label,
                amount: (amountCents / 100).toStringAsFixed(2),
              ),
            ],
            merchantCountryCode: 'US',
            currencyCode: 'USD',
          ),
        ),
      );
      return true;
    } on stripe.StripeException catch (e) {
      debugPrint('[ApplePay] StripeException: ${e.error.code} - ${e.error.message}');
      if (e.error.code == stripe.FailureCode.Canceled) return false;
      // If Apple Pay fails, fall back to card sheet
      return _confirmCardSheet(amountCents, label);
    } catch (e) {
      debugPrint('[ApplePay] Error: $e');
      return _confirmCardSheet(amountCents, label);
    }
  }

  /// Google Pay: present native Google Pay sheet via Stripe (hold only).
  Future<bool> _confirmGooglePay(int amountCents, String label) async {
    // Check if Google Pay is available on this device
    final supported = await stripe.Stripe.instance.isPlatformPaySupported(
      googlePay: const stripe.IsGooglePaySupportedParams(),
    );
    if (!supported) {
      debugPrint('[GooglePay] Not supported on this device');
      return _confirmCardSheet(amountCents, label);
    }

    try {
      final piResult = await ApiService.createPaymentIntent(amountCents: amountCents, holdOnly: true);
      final clientSecret = piResult['client_secret'] as String?;
      _heldPaymentIntentId = piResult['payment_intent_id'] as String?;
      if (clientSecret == null || clientSecret.startsWith('mock_')) return true;

      await stripe.Stripe.instance.confirmPlatformPayPaymentIntent(
        clientSecret: clientSecret,
        confirmParams: stripe.PlatformPayConfirmParams.googlePay(
          googlePay: stripe.GooglePayParams(
            testEnv: kDebugMode,
            merchantName: 'Cruise',
            merchantCountryCode: 'US',
            currencyCode: 'USD',
          ),
        ),
      );
      return true;
    } on stripe.StripeException catch (e) {
      debugPrint('[GooglePay] StripeException: ${e.error.code} - ${e.error.message}');
      if (e.error.code == stripe.FailureCode.Canceled) return false;
      return _confirmCardSheet(amountCents, label);
    } catch (e) {
      debugPrint('[GooglePay] Error: $e');
      return _confirmCardSheet(amountCents, label);
    }
  }

  /// Fallback: open Stripe's standard card payment sheet when native pay unavailable.
  Future<bool> _confirmCardSheet(int amountCents, String label) async {
    try {
      final piResult = await ApiService.createPaymentIntent(amountCents: amountCents, holdOnly: true);
      final clientSecret = piResult['client_secret'] as String?;
      _heldPaymentIntentId = piResult['payment_intent_id'] as String?;
      if (clientSecret == null || clientSecret.startsWith('mock_')) return true;

      await stripe.Stripe.instance.initPaymentSheet(
        paymentSheetParameters: stripe.SetupPaymentSheetParameters(
          paymentIntentClientSecret: clientSecret,
          merchantDisplayName: 'Cruise',
          style: ThemeMode.dark,
          appearance: const stripe.PaymentSheetAppearance(
            colors: stripe.PaymentSheetAppearanceColors(
              primary: Color(0xFFD4A843),
              background: Color(0xFF1A1A2E),
              componentBackground: Color(0xFF16213E),
              componentText: Color(0xFFFFFFFF),
            ),
          ),
        ),
      );
      await stripe.Stripe.instance.presentPaymentSheet();
      return true;
    } on stripe.StripeException catch (e) {
      debugPrint('[CardSheet] StripeException: ${e.error.code} - ${e.error.message}');
      if (e.error.code == stripe.FailureCode.Canceled) return false;
      rethrow;
    }
  }

  /// PayPal: open PayPal checkout screen.
  Future<bool> _confirmPayPal(int amountCents) async {
    final result = await Navigator.of(context).push<bool>(
      slideFromRightRoute(
        PayPalCheckoutScreen(
          amount: (amountCents / 100).toStringAsFixed(2),
          currency: 'USD',
        ),
      ),
    );
    return result == true;
  }

  /// Credit/debit card: authorize (hold) saved card via Stripe PaymentIntent.
  Future<bool> _confirmCard(int amountCents) async {
    final pmId = await LocalDataService.getStripePaymentMethodId();
    if (!mounted) return false;
    if (pmId == null || pmId.isEmpty) {
      throw Exception(S.of(context).pleaseAddPaymentFirst);
    }

    final piResult = await ApiService.createPaymentIntent(
      amountCents: amountCents,
      paymentMethodId: pmId,
      holdOnly: true,
    );
    _heldPaymentIntentId = piResult['payment_intent_id'] as String?;
    final clientSecret = piResult['client_secret'] as String?;
    final status = piResult['status'] as String?;
    if (clientSecret == null || clientSecret.startsWith('mock_')) return true;

    // If already succeeded (confirmed server-side), done
    if (status == 'succeeded') return true;

    // If requires_action (3D Secure), handle it client-side
    if (status == 'requires_action') {
      try {
        await stripe.Stripe.instance.handleNextAction(clientSecret);
        return true;
      } on stripe.StripeException catch (e) {
        if (e.error.code == stripe.FailureCode.Canceled) return false;
        rethrow;
      }
    }

    return true;
  }

  /// Creates a scheduled trip via the backend API and navigates to the scheduled rides list.
  Future<void> _createScheduledTrip() async {
    try {
      final userId = await ApiService.getCurrentUserId();
      if (userId == null || !mounted) return;

      final state = _ctrl.state;
      
      // Validar que scheduledAt no sea null
      if (state.scheduledAt == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).pleaseSelectDateTime),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      
      // Validar que no sea en el pasado
      final now = DateTime.now();
      if (state.scheduledAt!.isBefore(now)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).cannotSchedulePast),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      
      // Validar que sea al menos 30 minutos en el futuro
      final minAdvance = now.add(const Duration(minutes: 30));
      if (state.scheduledAt!.isBefore(minAdvance)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).schedule30MinAdvance),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      
      // Validar que no sea más de 30 días en el futuro
      final maxAdvance = now.add(const Duration(days: 30));
      if (state.scheduledAt!.isAfter(maxAdvance)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).scheduleMax30Days),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      await ApiService.createTrip(
        riderId: userId,
        pickupAddress: state.pickupLabel,
        dropoffAddress: state.dropoffLabel,
        pickupLat: state.pickup?.lat ?? 0,
        pickupLng: state.pickup?.lng ?? 0,
        dropoffLat: state.dropoff?.lat ?? 0,
        dropoffLng: state.dropoff?.lng ?? 0,
        fare: state.selectedOption?.priceEstimate,
        vehicleType: state.selectedOption?.name,
        scheduledAt: state.scheduledAt,
        isAirport: state.isAirportTrip,
      );

      if (!mounted) return;

      // Pop back to home and show booking confirmation
      Navigator.of(context).pop();
      HapticFeedback.heavyImpact();
      final isEs = Localizations.localeOf(context).languageCode == 'es';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF1E1E1E),
          duration: const Duration(seconds: 5),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.check_circle_rounded, color: Color(0xFFE8C547), size: 22),
                  const SizedBox(width: 10),
                  Text(
                    isEs ? '¡Reserva completada!' : 'Booking confirmed!',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                isEs
                    ? 'Te avisaremos cuando tengas un driver asignado.'
                    : 'We\'ll notify you when a driver is assigned.',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          margin: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + 8, 16, 0),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFFFF5252),
          content: Text(
            S.of(context).failedToScheduleRide(e.toString()),
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    }
  }

  /// Shows a "Payment Declined" or error dialog that blocks the user from
  /// proceeding. They must dismiss it and fix their payment method.
  void _showDeclinedDialog({required String title, required String message}) {
    final c = AppColors.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.credit_card_off_rounded,
                  color: Color(0xFFEF4444),
                  size: 28,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: c.gold,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    S.of(context).tryAgain,
                    style: const TextStyle(
                      fontSize: 16,
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
  }

  void _showPaymentMethodPicker(AppColors c, RideOption? option) {
    final loc = S.of(context);
    final methods = [
      if (Platform.isIOS) ('apple_pay', 'Apple Pay'),
      if (!Platform.isIOS) ('google_pay', 'Google Pay'),
      (
        'credit_card',
        _savedCardBrand != null && _savedCardLast4 != null
            ? '${_capitalizedBrand(_savedCardBrand)} •••• $_savedCardLast4'
            : loc.creditOrDebitCard,
      ),
      ('paypal', 'PayPal'),
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
          decoration: const BoxDecoration(
            color: Color(0xFF1A1A1A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // drag handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4.5,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(40),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  loc.paymentMethodLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 16),
                ...methods.map((m) {
                  final (id, label) = m;
                  final selected = id == _selectedPaymentMethod;
                  return GestureDetector(
                    onTap: () {
                      _setState(() => _selectedPaymentMethod = id);
                      Navigator.pop(ctx);
                    },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? c.gold.withValues(alpha: 0.08)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                        border: selected
                            ? Border.all(
                                color: c.gold.withValues(alpha: 0.4),
                                width: 1.2,
                              )
                            : null,
                      ),
                      child: Row(
                        children: [
                          if (id == 'apple_pay')
                            const Icon(Icons.apple, color: Colors.white, size: 24)
                          else if (id == 'google_pay')
                            const Icon(Icons.g_mobiledata_rounded, color: Colors.white, size: 24)
                          else
                            _paymentLogoWidget(id, 36),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              label,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (selected)
                            Icon(
                              Icons.check_circle_rounded,
                              color: c.gold,
                              size: 22,
                            )
                          else
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: c.gold.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                loc.added,
                                style: TextStyle(
                                  color: c.gold,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 8),
                // Manage payment accounts link
                GestureDetector(
                  onTap: () async {
                    Navigator.pop(ctx);
                    await Navigator.of(
                      context,
                    ).push(slideFromRightRoute(const PaymentAccountsScreen()));
                    await _loadLinkedPayments();
                    if (mounted) _showPaymentSheet(c, option);
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.settings_rounded, color: c.gold, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        loc.managePaymentAccounts,
                        style: TextStyle(
                          color: c.gold,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openCreditCardScreen(AppColors c, RideOption? option) async {
    final result = await Navigator.of(
      context,
    ).push<String>(slideFromRightRoute(const CreditCardScreen()));
    if (result != null && result.isNotEmpty) {
      String brand = 'card';
      String last4 = result;
      if (result.contains(':')) {
        final parts = result.split(':');
        brand = parts[0];
        last4 = parts[1];
      }
      await LocalDataService.saveCreditCardLast4(last4);
      await LocalDataService.saveCreditCardBrand(brand);
      await LocalDataService.linkPaymentMethod('credit_card');
    }
    await _loadLinkedPayments();
    if (mounted) _showPaymentSheet(c, option);
  }

  Future<void> _openPaymentAccountsAndReturn(
    AppColors c,
    RideOption? option,
  ) async {
    await Navigator.of(
      context,
    ).push(slideFromRightRoute(const PaymentAccountsScreen()));
    await _loadLinkedPayments();
    if (mounted) _showPaymentSheet(c, option);
  }

  // ── Payment helpers ──

  String _paymentLabel(String id) {
    final loc = S.of(context);
    switch (id) {
      case 'apple_pay':
        return 'Apple Pay';
      case 'google_pay':
        return 'Google Pay';
      case 'credit_card':
        if (_savedCardLast4 != null && _savedCardBrand != null) {
          return '${_capitalizedBrand(_savedCardBrand)} •••• $_savedCardLast4';
        }
        return loc.creditOrDebitCard;
      case 'paypal':
        return 'PayPal';
      default:
        return Platform.isIOS ? 'Apple Pay' : 'Google Pay';
    }
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

  void _cancelSearching() {
    _riderInitiatedCancel = true;
    _searchMapTimer?.cancel();
    _searchMapTimer = null;
    _splashTimer?.cancel();
    _splashTimer = null;
    _driverFoundTimer?.cancel();
    _driverFoundTimer = null;
    _dfCheckCtrl?.dispose();
    _dfCheckCtrl = null;
    _dfStaggerCtrl?.dispose();
    _dfStaggerCtrl = null;
    _dfShimmerCtrl?.dispose();
    _dfShimmerCtrl = null;
    _dfMsgTimer?.cancel();
    _dfMsgTimer = null;
    _searchStatusTimer?.cancel();
    _searchStatusTimer = null;
    _searchElapsedTimer?.cancel();
    _searchElapsedTimer = null;
    _searchCamCtrl?.dispose();
    _searchCamCtrl = null;
    _searchingShowMap = false;
    _searchingSplash = false;
    _driverFoundVisible = false;
    // Clean up map annotations so route/pins don't persist
    _cleanupMapAnnotations();
    _ctrl.cancelRide();
    _ctrl.reset();
    _navigatingToTracking = false;
  }

  /// Removes all trip-related polyline and pin annotations from the map.
  Future<void> _cleanupMapAnnotations() async {
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = null;
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr != null) {
      if (_routeAnnot != null) {
        try { await polyMgr.delete(_routeAnnot!); } catch (_) {}
        _routeAnnot = null;
      }
    }
    final ptMgr = _pointAnnotMgr;
    if (ptMgr != null) {
      if (_pickupAnnot != null) {
        try { await ptMgr.delete(_pickupAnnot!); } catch (_) {}
        _pickupAnnot = null;
      }
      if (_dropoffAnnot != null) {
        try { await ptMgr.delete(_dropoffAnnot!); } catch (_) {}
        _dropoffAnnot = null;
      }
    }
    _showPinLabels = false;
    _labelsRevealed = false;
  }

  /// Shows a confirmation dialog before canceling the ride search.
  void _confirmCancelSearching() {
    final c = AppColors.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          S.of(context).cancelRideQuestion,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          S.of(context).cancelRideMsg,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 14,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              S.of(context).keepWaiting,
              style: TextStyle(color: c.gold, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _cancelSearching();
              // Navigate to home screen with fade transition
              if (mounted) {
                Navigator.of(context).pushAndRemoveUntil(
                  smoothFadeRoute(const HomeScreen()),
                  (_) => false,
                );
              }
            },
            child: Text(
              S.of(context).yesCancelBtn,
              style: const TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
