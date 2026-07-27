part of 'ride_request_screen.dart';

// ════════════════════════════════════════════════════════════
//  CONTROLLER — payment, search, scheduling
// ════════════════════════════════════════════════════════════

final _last4Re = RegExp(r'(\d{4})$');

extension _RideRequestController on _RideRequestScreenState {

  /// Shows an error SnackBar with a Retry action button (8-second duration).
  void _showRetrySnackBar(String message, VoidCallback onRetry) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Retry',
          textColor: const Color(0xFFE8C547),
          onPressed: onRetry,
        ),
        backgroundColor: const Color(0xFF1A1A1A),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  /// Show a dialog when the rider has no payment method on file.
  void _showAddPaymentMethodDialog() {
    final s = S.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          s.noPaymentMethod,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 20,
          ),
        ),
        content: Text(
          'Please add a payment method before booking a ride.',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 15),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              s.cancel,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _openCreditCardScreen(AppColors.of(context), null);
            },
            child: const Text(
              'Add Card',
              style: TextStyle(
                color: Color(0xFFE8C547),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

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

  /// Geocode the airport selection and apply it as either pickup or dropoff
  /// depending on [sel.direction]:
  ///   - toAirport  → airport becomes the DROPOFF; rider's current location auto-set as pickup
  ///   - fromAirport → airport becomes the PICKUP; rider sets their own dropoff
  Future<void> _autoApplyAirportSelection(AirportSelection sel) async {
    final places = PlacesService(ApiKeys.webServices);
    final ap = sel.airport;
    final isFrom = sel.direction == AirportDirection.fromAirport;

    // Save airport metadata on the controller so the dispatch payload
    // includes code / terminal / pickup_zone / flight — matches the
    // Shopify widget's createTrip body.
    _ctrl.setAirportMetadata(
      isAirport: true,
      code: ap.code,
      terminal: sel.terminal?.name,
      pickupZone: isFrom ? sel.arrivalDoor : sel.airline,
      flight: sel.flightNumber,
    );

    // Build geocode query
    final terminalPart = sel.terminal != null ? ', ${sel.terminal!.name}' : '';
    final departureSuffix = isFrom ? '' : ' Departures';
    final query = '${ap.name}$terminalPart$departureSuffix';

    // Build human-readable label
    final doorPart = isFrom && sel.arrivalDoor != null ? ' — ${sel.arrivalDoor}' : '';
    final airlinePart = !isFrom && sel.airline != null ? ' — ${sel.airline}' : '';
    final label = '${ap.code} · ${sel.terminal?.name ?? ap.name}$doorPart$airlinePart';

    PlaceDetails? details;
    try {
      final results = await places.autocomplete(query);
      if (!mounted) return;
      if (results.isNotEmpty) {
        details = await places.details(results.first.placeId);
      }
    } catch (_) {}

    // Fallback: search by airport name only
    if (details == null) {
      try {
        final results = await places.autocomplete(ap.name);
        if (!mounted) return;
        if (results.isNotEmpty) details = await places.details(results.first.placeId);
      } catch (_) {}
    }

    if (!mounted || details == null) return;

    if (isFrom) {
      // fromAirport: airport = pickup origin
      _ctrl.setPickup(details, label);
    } else {
      // toAirport: airport = dropoff destination
      _ctrl.setDropoff(details, label);
      // Auto-set current location as pickup if available
      if (_userLocation != null) {
        final curLabel = _currentAddress.isNotEmpty ? _currentAddress : 'Current location';
        _ctrl.setPickup(
          PlaceDetails(address: curLabel, lat: _userLocation!.latitude, lng: _userLocation!.longitude),
          curLabel,
        );
      }
    }

    // Fly map to airport
    final target = LatLng(details.lat, details.lng);
    _mapCtrl?.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(coordinates: mapbox.Position(target.longitude, target.latitude)),
        zoom: 16.5,
      ),
      mapbox.MapAnimationOptions(duration: 800),
    );
  }

  // Keep old name as alias for backward compat with any lingering call sites.
  Future<void> _autoSetAirportPickup(AirportSelection sel) =>
      _autoApplyAirportSelection(sel);

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
    final bankLast4 = await LocalDataService.getBankLast4();
    if (!mounted) return;
    _setState(() {
      _linkedPaymentMethods = linked;
      _savedCardLast4 = last4;
      _savedCardBrand = brand;
      _savedBankLast4 = bankLast4;
    });
    // Also try to restore payment methods from backend (survives reinstall)
    _restorePaymentMethodsFromBackend();
  }

  /// Fetch saved payment methods from backend and sync to local storage.
  /// This ensures cards survive app reinstalls and device switches.
  Future<void> _restorePaymentMethodsFromBackend() async {
    try {
      final methods = await ApiService.getMyPaymentMethods();
      if (methods.isEmpty) return;

      // ── Restore linked bank accounts (ACH) — method_type 'bank_account' ──
      final bankAccounts =
          methods.where((m) => m['method_type'] == 'bank_account').toList();
      if (bankAccounts.isNotEmpty) {
        final bank = bankAccounts.first;
        final bankPmId = bank['stripe_pm_id'] as String?;
        final bankDisplay = bank['display_name'] as String? ?? '';
        final bankLast4 = _last4Re.firstMatch(bankDisplay)?.group(1);
        if (bankPmId != null) {
          await LocalDataService.saveStripeBankPmId(bankPmId);
          if (bankLast4 != null) {
            await LocalDataService.saveBankLast4(bankLast4);
          }
          await LocalDataService.linkPaymentMethod('bank_account');
          if (mounted) {
            _setState(() {
              _linkedPaymentMethods.add('bank_account');
              _savedBankLast4 = bankLast4;
            });
          }
        }
      }

      // Find the default stripe_card
      final stripeCards = methods.where((m) => m['method_type'] == 'stripe_card').toList();
      if (stripeCards.isEmpty) return;
      final defaultCard = stripeCards.firstWhere(
        (m) => m['is_default'] == true,
        orElse: () => stripeCards.first,
      );
      final pmId = defaultCard['stripe_pm_id'] as String?;
      final displayName = defaultCard['display_name'] as String? ?? '';
      if (pmId == null) return;

      // Extract last4 and brand from display_name (e.g. "Visa ending in 4242")
      final last4Match = _last4Re.firstMatch(displayName);
      final last4 = last4Match?.group(1) ?? '****';
      final brand = displayName.split(' ').first.toLowerCase();

      // Save locally
      await LocalDataService.saveStripePaymentMethodId(pmId);
      await LocalDataService.saveCreditCardLast4(last4);
      await LocalDataService.saveCreditCardBrand(brand);
      await LocalDataService.linkPaymentMethod('credit_card');

      if (mounted) {
        _setState(() {
          _linkedPaymentMethods = {'credit_card'};
          _savedCardLast4 = last4;
          _savedCardBrand = brand;
        });
      }
    } catch (e) {
      debugPrint('[RideRequest] restorePaymentMethods failed: $e');
      // Non-fatal: local methods still work
    }
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
    } catch (e) {
      if (kDebugMode) debugPrint('[GPS] _initLocation error: $e');
      if (mounted) _setState(() => _fetchingLocation = false);
    }
  }

  void _onStateChange() {
    if (!mounted) return;
    final s = _ctrl.state;

    switch (s.phase) {
      case RiderPhase.previewRoute:
      case RiderPhase.selectingRide:
        // The sheet visibility is driven by the phase itself (Positioned
        // widget mounted in the Stack) and an AnimatedOpacity inside
        // _buildRoutePreviewSheet — no AnimationController coordination
        // is needed here. The previous _sheetCtrl / _sheetForceTimer
        // watchdog caused races where the sheet stayed empty on iOS.
        //
        // Start cinematic + route draw as soon as any route is available.
        // Estimated route (2 points — straight-line placeholder) triggers
        // markers+tilt; the real road-snapped route (≥3 points, short OR
        // long trip) triggers the gold polyline draw. The >15 threshold
        // previously used here dropped short real routes (≤15 pts) that
        // arrived after the cinematic — they were never drawn and the
        // "Finding best route" spinner never stopped.
        if (s.route != null && s.pickup != null && s.dropoff != null) {
          final isRealRoute = s.route!.points.length >= 3;
          if (isRealRoute) _fetchingRoute = false;

          if (!_cinematicDone && !_cinematicRunning) {
            _drawRoute();
          } else if (isRealRoute && _routeAnnot == null && !_cinematicRunning) {
            // Real route arrived AFTER the cinematic finished but the
            // polyline was never drawn (cinematic ran on the estimated
            // 2-point route). Draw it now. The !_cinematicRunning guard
            // prevents a DUPLICATE draw if this fires while the
            // cinematic's own _animateGoldRoute is still in progress.
            final pts = _capRouteEndpoints(List<LatLng>.from(s.route!.points));
            _buildRouteMarkers();
            unawaited(_animateGoldRoute(pts));
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
            // Collapse to the single horizontal card so the rider lands
            // on the picked tier directly, not on the 3-card grid.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _setState(() => _gridExpanded = false);
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
          _searchStatusIdx = 0;
          _searchElapsedSec = 0;
          _searchStatusTimer?.cancel();
          // 3500ms rotation — matches the Shopify widget's __vrRotateMsg
          // cadence so the message cycles identically.
          _searchStatusTimer = Timer.periodic(const Duration(milliseconds: 3500), (_) {
            if (mounted) {
              _setState(() => _searchStatusIdx++);
              _animateSearchCameraToAngle(_searchStatusIdx);
            }
          });
          _searchElapsedTimer?.cancel();
          _searchElapsedTimer = Timer.periodic(const Duration(seconds: 2), (_) {
            if (mounted) _setState(() => _searchElapsedSec += 2);
          });
          // Force immediate rebuild so bottom card shows right away (no black flash)
          _setState(() => _searchingShowMap = true);
          // Trigger cinematic sequence on searching phase open
          _replayCinematicIfRouteAvailable();
        }
        break;
      case RiderPhase.driverAssigned:
        // If rider already cancelled, ignore stale driver assignment
        if (_riderInitiatedCancel) break;
        // Signal SearchingDriverScreen to pop immediately if still visible
        _driverMatchedNotifier.value = true;
        // Show premium "Driver Found" overlay, then auto-navigate quickly
        if (!_driverFoundVisible && !_navigatingToTracking) {
          _driverFoundVisible = true;
          HapticService.heavyImpact();

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
          // Navigate quickly — just enough time for checkmark + haptic to register
          _driverFoundTimer = Timer(const Duration(milliseconds: 1800), () {
            if (!mounted) return;
            _ctrl.transitionToArriving();
          });
        }
        break;
      case RiderPhase.driverArriving:
        // Don't navigate while SearchingDriverScreen is still on the stack —
        // the post-pop check in _startRideDirectly will call _goToTracking instead.
        if (_searchingScreenShowing) break;
        if (!_navigatingToTracking) {
          _navigatingToTracking = true;
          // Keep overlay visible during slide-in transition — hide after push
          _driverFoundTimer?.cancel();
          _goToTracking();
          // Overlay is hidden in _goToTracking after Navigator.push starts
        }
        break;
      case RiderPhase.cancelled:
        _searchingShowMap = false;
        _searchingSplash = false;
        _searchMapTimer?.cancel();
        _searchMapTimer = null;
        _splashTimer?.cancel();
        _splashTimer = null;
        _cleanupMapAnnotations();
        // If SearchingDriverScreen is still on the stack, don't navigate away —
        // the await in _startRideDirectly will handle cleanup once the screen pops.
        if (_searchingScreenShowing) break;
        // Rider already confirmed cancellation — just go home
        if (_riderInitiatedCancel) {
          _riderInitiatedCancel = false;
          _cancelDialogShown = false;
          _ctrl.reset();
          if (mounted) {
            Navigator.of(context).pushAndRemoveUntil(
              smoothFadeRoute(const HomeScreen()),
              (_) => false,
            );
          }
          break;
        }
        // ── Auto-cancel (10 min on-demand / 30 min scheduled) ─────────
        // The backend will auto-cancel the trip when no driver picks it
        // up inside the deadline. That is a friendly system message, not
        // an error — so instead of the intrusive dialog we flash a gold
        // SnackBar and slide the rider straight back to home so they
        // can immediately request again.
        if (RiderTripCancelCodes.isNoDriverAutoCancel(s.cancelCode)) {
          if (_cancelDialogShown) break; // dedup
          _cancelDialogShown = true;
          // Capture before the post-frame callback so we don't read
          // freshly-reset state.
          final cancelCodeForToast = s.cancelCode;
          final rawReasonForToast = s.cancelReason;
          final friendlyMessage = S.of(context).cancelCodeMessage(
                cancelCodeForToast,
                rawReason: rawReasonForToast,
              );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            // Fire the SnackBar on the root ScaffoldMessenger BEFORE
            // popping to HomeScreen — the root messenger survives the
            // Navigator replacement so the toast shows up on the home
            // screen after the transition.
            final rootMessenger = ScaffoldMessenger.maybeOf(context);
            rootMessenger?.clearSnackBars();
            rootMessenger?.showSnackBar(
              SnackBar(
                behavior: SnackBarBehavior.floating,
                backgroundColor: const Color(0xFF1a1a1a),
                content: Row(
                  children: [
                    const Icon(Icons.info_outline,
                        color: Color(0xFFE8C547), size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        friendlyMessage,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
                duration: const Duration(seconds: 5),
                margin: const EdgeInsets.all(16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(
                      color: Color(0xFFE8C547), width: 1),
                ),
              ),
            );
            _ctrl.reset();
            Navigator.of(context).pushAndRemoveUntil(
              smoothFadeRoute(const HomeScreen()),
              (_) => false,
            );
            // Don't reset _cancelDialogShown here — _ctrl.reset() above
            // already starts a fresh state, and leaving the flag true
            // until the next ride request prevents a re-entrant
            // RiderPhase.cancelled emission from firing this branch
            // twice in the same frame.
          });
          break;
        }
        // Guard: only show one cancel dialog per cancellation event
        if (_cancelDialogShown) break;
        _cancelDialogShown = true;
        final cancelCodeForDialog = s.cancelCode;
        final rawReasonForDialog = s.cancelReason;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          // Translate via cancelCodeMessage so the dialog content is in
          // the phone's language even when the controller stored an
          // English fallback string in cancelReason.
          final displayReason = S.of(context).cancelCodeMessage(
                cancelCodeForDialog,
                rawReason: rawReasonForDialog,
              );
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (dialogCtx) => AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Row(
                children: [
                  const Icon(Icons.info_outline, color: Colors.orange, size: 28),
                  const SizedBox(width: 10),
                  Text(S.of(context).tripCancelled),
                ],
              ),
              content: Text(displayReason, style: const TextStyle(fontSize: 15)),
              actions: [
                TextButton(
                  onPressed: () {
                    _cancelDialogShown = false;
                    Navigator.of(dialogCtx).pop();
                    _ctrl.reset();
                    if (mounted) {
                      Navigator.of(context).pushAndRemoveUntil(
                        smoothFadeRoute(const HomeScreen()),
                        (_) => false,
                      );
                    }
                  },
                  child: Text(S.of(context).okBtn),
                ),
              ],
            ),
          );
        });
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

    // Validate payment method exists before proceeding
    if (!_hasAnyPaymentMethod && _selectedPaymentMethod != 'test_mode') {
      _showAddPaymentMethodDialog();
      return;
    }

    _rideFlowLocked = true;
    setSheetState(() => _isProcessingPayment = true);
    _setState(() => _isProcessingPayment = true);
    // Safety fuse — see _startRideDirectly. 45 s without a finished
    // payment IPC frees the button so the rider can retry.
    _stuckPaymentFuse?.cancel();
    _stuckPaymentFuse = Timer(const Duration(seconds: 45), () {
      if (!mounted) return;
      if (_isProcessingPayment || _rideFlowLocked) {
        debugPrint('[RideRequest] payment fuse fired (modal) — clearing stuck state');
        _rideFlowLocked = false;
        _setState(() => _isProcessingPayment = false);
        try { setSheetState(() => _isProcessingPayment = false); } catch (_) {}
      }
    });

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
        _showRetrySnackBar(
          S.of(context).paymentDeclinedMsg,
          () => _processPayment(context, AppColors.of(context), option, setSheetState),
        );
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
      _stuckPaymentFuse?.cancel();
      _stuckPaymentFuse = null;
      _rideFlowLocked = false;
      // Safety net: ensure button never stays stuck regardless of exception path.
      if (mounted) {
        try { setSheetState(() => _isProcessingPayment = false); } catch (_) {}
        _setState(() => _isProcessingPayment = false);
      }
    }
  }

  /// Processes payment directly from the route preview sheet.
  Future<void> _startRideDirectly(AppColors c, RideOption? option) async {
    if (option == null) return;
    if (_rideFlowLocked || _isProcessingPayment) return;

    // Validate payment method exists before proceeding
    if (!_hasAnyPaymentMethod && _selectedPaymentMethod != 'test_mode') {
      _showAddPaymentMethodDialog();
      return;
    }

    _rideFlowLocked = true;
    // Show the spinner immediately so the rider sees feedback even
    // before the native sheet opens. The try/finally below guarantees
    // it's reset on every exit path (success, cancel, error, unmount).
    _setState(() => _isProcessingPayment = true);
    // Safety fuse: if anything below hangs (Stripe SDK never returns,
    // OS sheet stuck, etc.) force-release after 45 s so the button
    // can't get permanently locked.
    _stuckPaymentFuse?.cancel();
    _stuckPaymentFuse = Timer(const Duration(seconds: 45), () {
      if (!mounted) return;
      if (_isProcessingPayment || _rideFlowLocked) {
        debugPrint('[RideRequest] payment fuse fired — clearing stuck state');
        _rideFlowLocked = false;
        _setState(() => _isProcessingPayment = false);
      }
    });

    try {
      final nav = Navigator.of(context);

      // Test mode: skip payment entirely
      final bool isTestMode = _selectedPaymentMethod == 'test_mode';

      // Native pay (Apple/Google Pay/PayPal): OS sheet must appear first.
      // Card / sandbox: payment runs inside the searching screen animation.
      final bool isNativePay = !isTestMode && !AppConfig.sandboxPayments &&
          (_selectedPaymentMethod == 'apple_pay' ||
              _selectedPaymentMethod == 'google_pay' ||
              _selectedPaymentMethod == 'paypal');

      // Tap to Pay: open the NFC screen FIRST so the rider taps a card,
      // then proceed to dispatch. Same UX pattern as native pay (sheet
      // before searching). Without this branch the flow used to fall
      // through to requestRide() with no charge actually attempted, and
      // the searching screen's paymentCallback called _confirmNativePayment
      // which fails for tap_to_pay → rider got bounced back to home.
      final bool isTapToPay = _selectedPaymentMethod == 'tap_to_pay';
      if (isTapToPay && !isTestMode) {
        // Apply 10% promo when active so the charged amount matches the
        // price the rider saw on the picked vehicle card.
        final double effectivePrice = widget.applyPromo
            ? option.priceEstimate * 0.9
            : option.priceEstimate;
        final amountCents = (effectivePrice * 100).round();
        bool ok;
        try {
          ok = await _confirmTapToPay(amountCents, option);
        } catch (e) {
          debugPrint('Tap to Pay error: $e');
          ok = false;
        }
        if (!mounted) return;
        if (!ok) {
          // User cancelled the NFC sheet or the charge failed —
          // release the lock and stay on the ride request screen.
          _stuckPaymentFuse?.cancel();
          _setState(() => _isProcessingPayment = false);
          _rideFlowLocked = false;
          return;
        }
      }

      bool nativePayFailed = false;
      // Confirm payment for ALL non-test methods before creating the trip.
      // This ensures the hold is placed and verified before dispatching drivers.
      if (!isTestMode) {
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
          debugPrint('Payment error: $e');
          
          // Try smart retry with fallback options
          _setState(() => _isProcessingPayment = false);
          final double effectivePrice = widget.applyPromo
              ? option.priceEstimate * 0.9
              : option.priceEstimate;
          final amountCents = (effectivePrice * 100).round();
          final retryOk = await _handlePaymentFailure(
            error: e,
            amountCents: amountCents,
            originalMethod: _selectedPaymentMethod,
            option: option,
          );
          if (!retryOk || !mounted) {
            _rideFlowLocked = false;
            return; // User cancelled or retry failed
          }
          // Retry succeeded, continue with ride request
          _setState(() => _isProcessingPayment = true);
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

      // Start ride request BEFORE showing the searching screen so the map
      // bottom card renders behind the animation. When the screen fades out,
      // the bottom card is already visible — no black flash.
      _ctrl.setHeldPaymentIntentId(_heldPaymentIntentId);
      _driverMatchedNotifier.value = false; // Reset for this request
      unawaited(_ctrl.requestRide());

      _searchingScreenShowing = true;
      bool cancelled;
      try {
        cancelled = await nav.push<bool>(
              searchingDriverRoute(
                onCancel: _cancelSearching,
                paymentCallback: null, // Payment already confirmed before requestRide()
                initiallyDeclined: nativePayFailed,
                onPaymentDeclined: () => paymentDeclinedFlag = true,
                driverFound: _driverMatchedNotifier,
              ),
            ) ??
            false;
      } finally {
        _searchingScreenShowing = false;
      }

      // If the trip was cancelled by the backend during the animation,
      // _onStateChange was blocked (flag was true). Handle navigation now.
      if (!mounted) return;

      // Handle all states that may have arrived while SearchingDriverScreen was visible.
      final phase = _ctrl.state.phase;

      // If rider initiated cancel, do NOT navigate to tracking even if a
      // stale Firestore event set driverAssigned during the 300ms window.
      if (_riderInitiatedCancel) {
        _riderInitiatedCancel = false;
        // Prevent _onStateChange from showing a "trip cancelled" dialog —
        // the rider already knows they cancelled.
        _cancelDialogShown = true;
        if (phase != RiderPhase.cancelled) {
          _ctrl.forcePhase(RiderPhase.cancelled);
        }
        
        // Clean up all resources before navigating
        _searchMapTimer?.cancel();
        _searchStatusTimer?.cancel();
        _searchElapsedTimer?.cancel();
        _driverFoundTimer?.cancel();
        _driverMatchedNotifier.dispose();
        _heldPaymentIntentId = null;
        _searchingScreenShowing = false;
        _navigatingToTracking = false;
        
        _ctrl.reset();
        // Navigate to home screen after cancel
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            smoothFadeRoute(const HomeScreen()),
            (_) => false,
          );
        }
        return;
      }

      // Driver assigned/arriving → show "Driver Found" overlay first, THEN tracking.
      //
      // Important: if the backend matched a driver while the user was still
      // on the "Confirming your ride" sheet, the phase here is already
      // driverAssigned. Jumping straight to the overlay skips the
      // "Finding the best driver for you…" bottom card entirely, which made
      // it look like a hard cut from payment → driver-found. Instead we:
      //   1) force the searching card on for a minimum display time
      //   2) wait that long
      //   3) THEN fire the driver-found overlay
      // so the rider always sees the map with the route + searching card
      // before the driver-found celebration.
      if ((phase == RiderPhase.driverArriving || phase == RiderPhase.driverAssigned) &&
          !_navigatingToTracking) {
        _searchMapTimer?.cancel();
        _setState(() {
          _searchingShowMap = true;
          _searchingSplash = false;
        });
        // Trigger the cinematic camera replay (fits pickup→dropoff + route)
        // so the user gets the same visual as if the backend had been slow.
        _replayCinematicIfRouteAvailable();
        Future.delayed(const Duration(milliseconds: 2500), () {
          if (!mounted) return;
          // Abort if the user cancelled or the phase moved on during the wait.
          final p = _ctrl.state.phase;
          if (p != RiderPhase.driverAssigned &&
              p != RiderPhase.driverArriving) {
            return;
          }
          if (_navigatingToTracking) return;
          // Force driverAssigned so _onStateChange shows the overlay
          if (p == RiderPhase.driverArriving) {
            _ctrl.forcePhase(RiderPhase.driverAssigned);
          }
          _driverFoundVisible = false; // reset so _onStateChange shows it fresh
          _onStateChange();
        });
        return;
      }

      // Payment successful, driver not yet assigned.
      // Per product decision: do NOT push WaitingForDriverScreen
      // ("Almost ready..." with the map). The matching screen + the
      // "Almost there..." card on the ride_request_screen below already
      // cover this state, and the third screen was redundant.
      // We just bail; _onStateChange will run again when phase moves to
      // driverAssigned/driverArriving and route to the tracking screen.
      if (phase == RiderPhase.searchingDriver && !_navigatingToTracking) {
        return;
      }

      // Driver already started the trip (extreme case: very fast driver) → go directly to tracking.
      if ((phase == RiderPhase.onTrip || phase == RiderPhase.completed) &&
          !_navigatingToTracking) {
        _navigatingToTracking = true;
        _goToTracking();
        return;
      }

      if (_ctrl.state.phase == RiderPhase.cancelled && !_cancelDialogShown) {
        // Guard: if SearchingDriverScreen is still on the stack, defer the
        // navigation. The post-await block (_riderInitiatedCancel branch)
        // will handle pushAndRemoveUntil(HomeScreen) AFTER the searching
        // screen has popped — otherwise SearchingDriverScreen's own
        // Navigator.pop(true) fires after we've already replaced the stack
        // with HomeScreen, popping HomeScreen and leaving a black screen.
        if (_searchingScreenShowing) {
          return;
        }
        _cancelDialogShown = true;
        final rawReason = _ctrl.state.cancelReason;
        final cancelCode = _ctrl.state.cancelCode;
        // Use the canonical cancelCode when available (set by the new
        // auto-cancel paths). Fall back to the legacy string heuristic
        // for older paths that only populate cancelReason.
        final isAutoNoDriver =
            RiderTripCancelCodes.isNoDriverAutoCancel(cancelCode);
        final isNoDrivers = isAutoNoDriver ||
            (rawReason != null &&
                (rawReason.toLowerCase().contains('no hay driver') ||
                    rawReason.toLowerCase().contains('no driver')));
        // ── Client-side pre-flight errors (no internet, no session, create failed)
        // These mean the trip was NEVER created.  Instead of silently dumping
        // the rider back to home, show an inline SnackBar so they can retry.
        final isClientError = cancelCode == RiderTripCancelCodes.clientNoInternet ||
            cancelCode == RiderTripCancelCodes.clientNoSession ||
            cancelCode == RiderTripCancelCodes.clientCreateFailed ||
            cancelCode == RiderTripCancelCodes.clientConnectionError;
        if (isClientError) {
          _ctrl.reset();
          final msg = rawReason ?? S.of(context).tripCancelled;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              backgroundColor: const Color(0xFF1a1a1a),
              content: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.orange, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      msg,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              duration: const Duration(seconds: 5),
              margin: const EdgeInsets.all(16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Colors.orange, width: 1),
              ),
            ),
          );
          return;
        }
        _ctrl.reset();
        // For the smooth auto-cancel flow we show a gold SnackBar on the
        // home screen instead of the intrusive dialog. Fire it BEFORE
        // the navigation so the root messenger survives the replacement.
        if (isAutoNoDriver) {
          final rootMessenger = ScaffoldMessenger.maybeOf(context);
          rootMessenger?.clearSnackBars();
          rootMessenger?.showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              backgroundColor: const Color(0xFF1a1a1a),
              content: Row(
                children: [
                  const Icon(Icons.info_outline,
                      color: Color(0xFFE8C547), size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      S.of(context).cancelCodeMessage(
                            cancelCode,
                            rawReason: rawReason,
                          ),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              duration: const Duration(seconds: 5),
              margin: const EdgeInsets.all(16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(
                    color: Color(0xFFE8C547), width: 1),
              ),
            ),
          );
          Navigator.of(context).pushAndRemoveUntil(
            smoothFadeRoute(const HomeScreen()),
            (_) => false,
          );
          return;
        }
        Navigator.of(context).pushAndRemoveUntil(
          smoothFadeRoute(const HomeScreen()),
          (_) => false,
        );
        Future.delayed(const Duration(milliseconds: 600), () {
          if (!mounted) return;
          // Translate via cancelCodeMessage to honour the phone language.
          final localizedBody = S.of(context).cancelCodeMessage(
                cancelCode,
                rawReason: rawReason,
              );
          showDialog(
            context: Navigator.of(context, rootNavigator: true).context,
            barrierDismissible: true,
            builder: (dialogCtx) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(children: [
                Icon(isNoDrivers ? Icons.search_off_rounded : Icons.info_outline,
                    color: isNoDrivers ? const Color(0xFFE8C547) : Colors.orange, size: 28),
                const SizedBox(width: 10),
                Expanded(child: Text(isNoDrivers ? S.of(context).noDriversAvailableTitle : S.of(context).tripCancelled,
                    style: const TextStyle(fontSize: 17))),
              ]),
              content: Text(localizedBody, style: const TextStyle(fontSize: 15)),
              actions: [TextButton(onPressed: () => Navigator.of(dialogCtx).pop(), child: Text(S.of(context).okBtn))],
            ),
          );
        });
        return;
      }

      if (cancelled == true) {
        if (!mounted) return;
        // Determine cancel reason for the dialog
        final rawReason = _ctrl.state.cancelReason;
        final isNoDrivers = rawReason != null &&
            (rawReason.toLowerCase().contains('no hay driver') ||
             rawReason.toLowerCase().contains('no driver'));
        final displayTitle = isNoDrivers
            ? S.of(context).noDriversAvailableTitle
            : S.of(context).tripCancelled;
        final displayMsg = isNoDrivers
            ? S.of(context).noDriversAvailableMsg
            : (rawReason ?? S.of(context).tripCancelled);
        _ctrl.reset();
        // Navigate home cleanly
        final navRoot = Navigator.of(context, rootNavigator: true);
        Navigator.of(context).pushAndRemoveUntil(
          smoothFadeRoute(const HomeScreen()),
          (_) => false,
        );
        // Show dialog on home screen after a short delay
        Future.delayed(const Duration(milliseconds: 600), () {
          if (!navRoot.mounted) return;
          showDialog(
            context: navRoot.context,
            barrierDismissible: true,
            builder: (dialogCtx) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Icon(isNoDrivers ? Icons.search_off_rounded : Icons.info_outline,
                    color: isNoDrivers ? const Color(0xFFE8C547) : Colors.orange, size: 28),
                  const SizedBox(width: 10),
                  Expanded(child: Text(displayTitle, style: const TextStyle(fontSize: 17))),
                ],
              ),
              content: Text(displayMsg, style: const TextStyle(fontSize: 15)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(),
                  child: Text(S.of(context).ok),
                ),
              ],
            ),
          );
        });
        return;
      }
      if (nativePayFailed || paymentDeclinedFlag) {
        // Payment failed after the ride request was already dispatched — cancel it.
        _ctrl.cancelRide();
        _ctrl.reset();
        if (mounted) _setState(() => _showPaymentDeclinedBanner = true);
        return;
      }
      // requestRide() already started above — nothing more to do here
    } finally {
      _stuckPaymentFuse?.cancel();
      _stuckPaymentFuse = null;
      _rideFlowLocked = false;
      if (mounted) _setState(() => _isProcessingPayment = false);
    }
  }

  /// Triggers the native payment confirmation for the selected payment method.
  /// Returns true if payment was authorized, false if user cancelled.
  /// Throws on failure.
  Future<bool> _confirmNativePayment(RideOption? option) async {
    if (option == null) return false;
    final double effectivePrice = widget.applyPromo
        ? option.priceEstimate * 0.9
        : option.priceEstimate;
    final amountCents = (effectivePrice * 100).round();
    final label = 'Cruise · ${option.name}';

    // The backend hard-caps PaymentIntents at $1,000 (payments.py). A fare
    // outside (0, $1,000] means the route estimate is corrupt — fail fast
    // with a clear error instead of letting the backend's 400 surface as a
    // bogus "Payment Declined" (App Store rejection, Jul 2026).
    if (amountCents <= 0 || amountCents > 100000) {
      debugPrint('[Payment] invalid fare amount: $amountCents cents — aborting before backend call');
      throw const ApiException(400, 'invalid_fare_amount');
    }

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
        // Unrecognised payment method — never allow payment to proceed silently.
        debugPrint('[Payment] _confirmNativePayment: unknown method "$_selectedPaymentMethod"');
        return false;
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
    } on stripe.StripeException catch (e, stack) {
      debugPrint('[ApplePay] StripeException: ${e.error.code} - ${e.error.message}');
      if (e.error.code == stripe.FailureCode.Canceled) return false;
      // Apple Pay was declined by the bank — surface the error so the caller
      // shows the "Payment declined" banner instead of opening a card sheet.
      // Report to Crashlytics: a silent decline during App Review once cost
      // us a rejection with no diagnostics.
      FirebaseCrashlytics.instance.recordError(e, stack, reason: 'ApplePay confirm failed: ${e.error.code}');
      rethrow;
    } catch (e, stack) {
      debugPrint('[ApplePay] Error: $e');
      FirebaseCrashlytics.instance.recordError(e, stack, reason: 'ApplePay confirm error');
      rethrow;
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
      // Google Pay was declined — surface the error so the caller shows the
      // "Payment declined" banner instead of silently opening a card sheet.
      rethrow;
    } catch (e) {
      debugPrint('[GooglePay] Error: $e');
      rethrow;
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
  /// Returns true on success, false when the user explicitly cancels.
  /// Rethrows on unexpected errors so the caller shows the declined banner.
  Future<bool> _confirmPayPal(int amountCents) async {
    late final bool? result;
    try {
      result = await Navigator.of(context).push<bool>(
        slideFromRightRoute(
          PayPalCheckoutScreen(
            amount: (amountCents / 100).toStringAsFixed(2),
            currency: 'USD',
          ),
        ),
      );
    } catch (e) {
      // Navigator or PayPalCheckoutScreen threw — surface this so the caller
      // can show the payment-declined banner rather than silently returning false.
      debugPrint('[PayPal] checkout error: $e');
      rethrow;
    }
    // result == null  → user pressed back (cancel, no error)
    // result == false → PayPal screen reported a failure we should surface
    // result == true  → authorised
    if (result == false) {
      debugPrint('[PayPal] checkout returned false — treating as declined');
      throw Exception('PayPal payment was declined or failed on the PayPal screen.');
    }
    return result == true;
  }

  /// Credit/debit card: authorize (hold) saved card via Stripe PaymentIntent.
  /// Falls back to card sheet if no saved card or if server-side confirm fails.
  Future<bool> _confirmCard(int amountCents) async {
    final pmId = await LocalDataService.getStripePaymentMethodId();
    if (!mounted) return false;
    // If no saved card, fall back to the Stripe card sheet
    if (pmId == null || pmId.isEmpty) {
      return _confirmCardSheet(amountCents, 'Cruise');
    }

    try {
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

      // If requires_capture (hold authorized), done
      if (status == 'requires_capture') return true;

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
    } catch (e) {
      debugPrint('[Card] Saved card failed: $e');
      // Do NOT fall back to card sheet on payment failures.
      // The user already has a saved card; if it fails (insufficient funds,
      // expired, etc.) we must stop and show the error.
      rethrow;
    }
  }

  /// ACH debit via the saved bank PaymentMethod — same server-confirmed
  /// PaymentIntent path as the saved card, with two ACH differences:
  /// no manual capture (Stripe settles ACH asynchronously, so we don't
  /// pass holdOnly) and status 'processing' is accepted as payment
  /// initiated (Stripe confirms the debit later — standard ACH flow).
  Future<bool> _confirmBankAccount(int amountCents, RideOption option) async {
    final pmId = await LocalDataService.getStripeBankPmId();
    if (!mounted) return false;
    if (pmId == null || pmId.isEmpty) {
      // No bank on file — reopen the picker so the rider can link one.
      await _showPaymentMethodPicker(AppColors.of(context), option);
      return false;
    }

    try {
      final piResult = await ApiService.createPaymentIntent(
        amountCents: amountCents,
        paymentMethodId: pmId,
      );
      _heldPaymentIntentId = piResult['payment_intent_id'] as String?;
      final clientSecret = piResult['client_secret'] as String?;
      final status = piResult['status'] as String?;
      if (clientSecret == null || clientSecret.startsWith('mock_')) return true;

      // Confirmed server-side.
      if (status == 'succeeded') return true;
      if (status == 'requires_capture') return true;
      // ACH: debit initiated, Stripe settles asynchronously.
      if (status == 'processing') return true;

      return true;
    } catch (e) {
      debugPrint('[Bank] Saved bank account failed: $e');
      // Same policy as saved cards: no silent fallback on payment failures.
      rethrow;
    }
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
      // Airport metadata is already stashed on the controller state by
      // _autoApplyAirportSelection — read it straight from there so both
      // scheduled createTrip and immediate dispatchRideRequest agree.
      final flight = state.airportFlight?.trim();
      final notes = (flight != null && flight.isNotEmpty)
          ? 'Flight: $flight'
          : null;

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
        airportCode: state.airportCode,
        terminal: state.airportTerminal,
        pickupZone: state.airportPickupZone,
        notes: notes,
      );

      if (!mounted) return;

      // Navigate to animated confirmation screen
      HapticService.heavyImpact();
      Navigator.of(context).pushAndRemoveUntil(
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 400),
          pageBuilder: (_, __, ___) => RideBookingConfirmedScreen(
            scheduledAt: state.scheduledAt!,
            pickupAddress: state.pickupLabel,
            dropoffAddress: state.dropoffLabel,
            vehicleType: state.selectedOption?.name ?? 'Comfort',
            fare: state.selectedOption?.priceEstimate ?? 0,
            pickupLat: state.pickup?.lat,
            pickupLng: state.pickup?.lng,
            dropoffLat: state.dropoff?.lat,
            dropoffLng: state.dropoff?.lng,
            routePoints: state.route?.points,
          ),
          transitionsBuilder: (_, anim, __, child) => FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
            child: child,
          ),
        ),
        (_) => false,
      );
    } catch (e) {
      if (!mounted) return;
      _showRetrySnackBar(
        S.of(context).failedToScheduleRide(e.toString()),
        _createScheduledTrip,
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

  Future<void> _showPaymentMethodPicker(AppColors c, RideOption? option) async {
    // Full-screen payment method picker (2×2 grid) — matches the
    // Shopify widget's pay overlay.
    //
    // Maps between the new screen's canonical ids (`apple_pay`,
    // `google_pay`, `card`, `test_mode`) and the app's existing storage
    // id `credit_card` — they're the same thing under the hood.
    final current =
        _selectedPaymentMethod == 'credit_card' ? 'card' : _selectedPaymentMethod;
    final picked = await showRidePaymentMethodPicker(
      context,
      currentMethod: current,
      // Test mode always visible — matches the web widget where the
      // Modo de Prueba tile is always in the picker so operators can
      // simulate a payment without a real card on file.
      showTestMode: true,
    );
    if (picked == null || !mounted) return;
    
    // Handle Tap to Pay selection
    if (picked == PaymentMethodId.tapToPay) {
      _setState(() => _selectedPaymentMethod = PaymentMethodId.tapToPay);
      return;
    }
    
    final mapped = picked == 'card' ? 'credit_card' : picked;
    _setState(() => _selectedPaymentMethod = mapped);
    if (mapped == 'credit_card' &&
        !_linkedPaymentMethods.contains('credit_card')) {
      // No card on file yet — jump straight to the credit-card entry screen.
      await _openCreditCardScreen(c, option);
    }
  }

  /// Confirms Tap to Pay payment using Stripe Terminal
  Future<bool> _confirmTapToPay(int amountCents, RideOption option) async {
    try {
      final double amount = amountCents / 100.0;
      
      final result = await showTapToPayScreen(
        context: context,
        amount: amount,
        currency: 'USD',
        rideDescription: option.name,
      );
      
      return result == true;
    } catch (e) {
      debugPrint('Tap to Pay error: $e');
      return false;
    }
  }

  /// Handles payment failure with automatic retry options.
  /// Shows a smart dialog that detects available alternatives and offers them.
  Future<bool> _handlePaymentFailure({
    required Object error,
    required int amountCents,
    required String originalMethod,
    required RideOption option,
  }) async {
    final s = S.of(context);
    
    // Parse error type for better messaging
    String errorTitle = s.paymentDeclined;
    String errorMessage = s.tryDifferentPaymentMethod;
    String errorCode = 'unknown';
    
    if (error is stripe.StripeException) {
      errorCode = error.error.code.toString();
      final declineCode = (error.error as dynamic)?.declineCode?.toString().toLowerCase() ?? '';
      final errCode = errorCode.toLowerCase();
      
      switch (error.error.code) {
        case stripe.FailureCode.Canceled:
          // User cancelled - no dialog needed
          return false;
        default:
          // Map specific decline codes to user-friendly localized messages
          if (declineCode == 'card_declined' || errCode.contains('card_declined')) {
            errorTitle = s.cardDeclined;
            errorMessage = s.cardDeclinedMsg;
            errorCode = 'card_declined';
          } else if (declineCode == 'insufficient_funds') {
            errorTitle = s.insufficientFunds;
            errorMessage = s.insufficientFundsMsg;
            errorCode = 'insufficient_funds';
          } else if (declineCode == 'expired_card' || errCode.contains('expired_card')) {
            errorTitle = s.cardExpired;
            errorMessage = s.cardExpiredMsg;
            errorCode = 'expired_card';
          } else if (declineCode == 'incorrect_number' || errCode.contains('incorrect_number')) {
            errorTitle = s.invalidCardNumber;
            errorMessage = s.invalidCardNumberMsg;
            errorCode = 'incorrect_number';
          } else if (declineCode == 'incorrect_cvc' || errCode.contains('incorrect_cvc')) {
            errorTitle = s.cardDeclined;
            errorMessage = 'Incorrect security code. Please check and try again.';
            errorCode = 'incorrect_cvc';
          } else if (declineCode == 'test_mode_live_card' || errCode.contains('test_mode_live_card')) {
            errorTitle = s.cardDeclined;
            errorMessage = 'This is a test card. Please use a real card for live payments.';
            errorCode = 'test_mode_live_card';
          } else if (declineCode == 'processing_error' || errCode.contains('processing_error')) {
            errorTitle = s.paymentDeclined;
            errorMessage = 'Payment processing error. Please try again.';
            errorCode = 'processing_error';
          } else if (declineCode == 'fraudulent') {
            errorTitle = s.paymentDeclined;
            errorMessage = 'This payment was flagged for security. Please contact your bank or try a different card.';
            errorCode = 'fraudulent';
          } else {
            errorTitle = s.paymentDeclined;
            errorMessage = s.genericPaymentError;
          }
      }
    } else if (error is ApiException) {
      // The backend rejected the payment request itself (invalid amount,
      // Stripe config, etc.) — this is NOT a card decline. Surface the real
      // reason instead of the misleading "Payment Declined" defaults.
      final msg = error.message;
      final msgLower = msg.toLowerCase();
      if (msgLower.contains('invalid_fare_amount') ||
          msgLower.contains('invalid payment amount')) {
        errorTitle = s.fareEstimateError;
        errorMessage = s.fareEstimateErrorMsg;
        errorCode = 'invalid_fare';
      } else {
        // Stripe errors arrive as a stringified dict: {message: …, code: …,
        // decline_code: …}. Extract the human message when possible.
        final m = RegExp(r'message: ([^,}]+)').firstMatch(msg);
        errorTitle = s.paymentDeclined;
        errorMessage = m != null
            ? m.group(1)!.trim()
            : (msg.isNotEmpty ? msg : s.genericPaymentError);
        errorCode = 'api_${error.statusCode}';
      }
    } else if (error is Map<String, dynamic>) {
      // Backend may return structured error with decline_code
      final backendDecline = (error['decline_code'] ?? error['code'])?.toString().toLowerCase() ?? '';
      final backendMsg = error['message']?.toString() ?? '';
      if (backendDecline == 'card_declined') {
        errorTitle = s.cardDeclined;
        errorMessage = s.cardDeclinedMsg;
        errorCode = 'card_declined';
      } else if (backendDecline == 'insufficient_funds') {
        errorTitle = s.insufficientFunds;
        errorMessage = s.insufficientFundsMsg;
        errorCode = 'insufficient_funds';
      } else if (backendMsg.toLowerCase().contains('no payment method')) {
        errorTitle = s.noPaymentMethod;
        errorMessage = 'Please add a payment method before booking.';
        errorCode = 'no_payment_method';
      } else {
        errorTitle = s.paymentDeclined;
        errorMessage = backendMsg.isNotEmpty ? backendMsg : s.genericPaymentError;
      }
    } else if (error.toString().toLowerCase().contains('paypal')) {
      errorTitle = s.paypalDeclined;
      errorMessage = s.paypalDeclinedMsg;
      errorCode = 'paypal_declined';
    } else if (error.toString().toLowerCase().contains('network') ||
               error.toString().toLowerCase().contains('timeout') ||
               error.toString().toLowerCase().contains('connection')) {
      errorTitle = s.networkError;
      errorMessage = s.networkErrorMsg;
      errorCode = 'network_error';
    }

    // Check for available fallback methods
    final availableMethods = await _getAvailablePaymentMethods();
    final hasAlternativeMethod = availableMethods.any((m) => m != originalMethod);
    final hasSavedCard = await LocalDataService.getStripePaymentMethodId() != null;

    // mounted guard required: two awaits above mean the user could have
    // navigated away (back-tap, app backgrounded etc) before we get here.
    if (!mounted) return false;

    // Show smart retry dialog
    final retryAction = await showDialog<_RetryAction>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _PaymentRetryDialog(
        title: errorTitle,
        message: errorMessage,
        errorCode: errorCode,
        hasAlternativeMethod: hasAlternativeMethod,
        hasSavedCard: hasSavedCard,
        originalMethod: originalMethod,
      ),
    );

    if (retryAction == null || !mounted) return false;

    switch (retryAction) {
      case _RetryAction.retrySame:
        // Retry with same method
        return await _retryWithSameMethod(amountCents, originalMethod, option);
        
      case _RetryAction.tryDifferentMethod:
        // Show payment method picker and retry
        final c = AppColors.of(context);
        await _showPaymentMethodPicker(c, option);
        if (!mounted) return false;
        return await _processPaymentWithSelectedMethod(amountCents, option);
        
      case _RetryAction.addNewCard:
        // Add new card and retry
        final c = AppColors.of(context);
        await _openCreditCardScreen(c, option);
        if (!mounted) return false;
        return await _confirmCard(amountCents);
        
      case _RetryAction.cancel:
        return false;
    }
  }

  /// Gets list of available payment methods
  Future<List<String>> _getAvailablePaymentMethods() async {
    final methods = <String>[];
    
    // Check for native pay
    if (AppPlatform.isIOS && await PaymentService.isApplePayAvailable()) {
      methods.add('apple_pay');
    }
    if (AppPlatform.isAndroid && await PaymentService.isGooglePayAvailable()) {
      methods.add('google_pay');
    }
    
    // Tap to Pay (Stripe Terminal NFC). Only available on Android until
    // Apple approves the proximity-reader entitlement for iOS.
    if (AppPlatform.isAndroid) {
      methods.add('tap_to_pay');
    }
    
    // Check for saved card
    if (await LocalDataService.getStripePaymentMethodId() != null) {
      methods.add('credit_card');
    }
    
    // PayPal is always available as option
    methods.add('paypal');
    
    return methods;
  }

  /// Retries payment with the same method (useful for transient errors)
  Future<bool> _retryWithSameMethod(int amountCents, String method, RideOption option) async {
    try {
      switch (method) {
        case 'apple_pay':
          return await _confirmApplePay(amountCents, option.name);
        case 'google_pay':
          return await _confirmGooglePay(amountCents, option.name);
        case 'tap_to_pay':
          return await _confirmTapToPay(amountCents, option);
        case 'credit_card':
          return await _confirmCard(amountCents);
        case 'paypal':
          return await _confirmPayPal(amountCents);
        default:
          // Fallback to card sheet
          return await _confirmCardSheet(amountCents, 'Cruise');
      }
    } catch (e) {
      debugPrint('[Retry] Same method failed again: $e');
      // If it fails again, don't recurse - let the caller handle it
      return false;
    }
  }

  /// Processes payment with currently selected method
  Future<bool> _processPaymentWithSelectedMethod(int amountCents, RideOption option) async {
    final isTestMode = _selectedPaymentMethod == 'test_mode';
    if (isTestMode) return true;
    
    final isNativePay = !AppConfig.sandboxPayments &&
        (_selectedPaymentMethod == 'apple_pay' ||
            _selectedPaymentMethod == 'google_pay');
    
    try {
      if (isNativePay) {
        return await _confirmNativePayment(option);
      } else if (_selectedPaymentMethod == 'tap_to_pay') {
        return await _confirmTapToPay(amountCents, option);
      } else if (_selectedPaymentMethod == 'paypal') {
        return await _confirmPayPal(amountCents);
      } else if (_selectedPaymentMethod == 'bank_account') {
        return await _confirmBankAccount(amountCents, option);
      } else {
        return await _confirmCard(amountCents);
      }
    } catch (e) {
      // Try to handle with retry dialog
      return await _handlePaymentFailure(
        error: e,
        amountCents: amountCents,
        originalMethod: _selectedPaymentMethod,
        option: option,
      );
    }
  }

// Kept for backwards-compat — no longer used but referenced by older
// call sites; leave in place until a dedicated cleanup pass.
// ignore: unused_element
void _showPaymentMethodPickerLegacy(AppColors c, RideOption? option) {
    final loc = S.of(context);
    final methods = [
      if (AppPlatform.isIOS) ('apple_pay', 'Apple Pay', true),
      if (!AppPlatform.isIOS) ('google_pay', 'Google Pay', true),
      ('tap_to_pay', 'Tap to Pay', true),
      (
        'credit_card',
        _savedCardBrand != null && _savedCardLast4 != null
            ? '${_capitalizedBrand(_savedCardBrand)} •••• $_savedCardLast4'
            : loc.creditOrDebitCard,
        true,
      ),
      ('paypal', 'PayPal', true),
      ('test_mode', 'Test Mode', true),
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
                  final (id, label, enabled) = m;
                  final selected = id == _selectedPaymentMethod;
                  return GestureDetector(
                    onTap: enabled
                        ? () {
                            _setState(() => _selectedPaymentMethod = id);
                            Navigator.pop(ctx);
                          }
                        : null,
                    child: Opacity(
                      opacity: enabled ? 1.0 : 0.45,
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
                            else if (id == 'tap_to_pay')
                              Icon(Icons.contactless, color: Color(0xFF4A90D9), size: 24)
                            else if (id == 'test_mode')
                              const Icon(Icons.bug_report_rounded, color: Color(0xFFFF3B30), size: 24)
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
                            if (!enabled)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFD4A843).withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Text(
                                  'Coming Soon',
                                  style: TextStyle(
                                    color: Color(0xFFD4A843),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              )
                            else if (selected)
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
      // The new card becomes the active payment method so the rider
      // lands back on the vehicle sheet (photo 2) ready to Request —
      // NOT on the Payment panel again (that made it show twice).
      _setState(() => _selectedPaymentMethod = 'credit_card');
    }
    await _loadLinkedPayments();
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

  /// True when the rider has a usable payment method selected. For
  /// platform rails (Apple Pay / Google Pay / PayPal / Test Mode) the
  /// method id alone is enough. For 'credit_card' we must also have a
  /// card on file, otherwise the request button would enable a ride
  /// that can't actually be charged.
  bool get _hasAnyPaymentMethod {
    switch (_selectedPaymentMethod) {
      case 'test_mode':
      case 'paypal':
      case 'apple_pay':
      case 'google_pay':
      case 'tap_to_pay':
        return true;
      case 'credit_card':
        return _linkedPaymentMethods.contains('credit_card') &&
            _savedCardLast4 != null;
      case 'bank_account':
        return _linkedPaymentMethods.contains('bank_account');
      default:
        return _linkedPaymentMethods.isNotEmpty;
    }
  }

  String _paymentLabel(String id) {
    if (id.isEmpty || id == 'none') return S.of(context).selectPaymentMethod;
    final loc = S.of(context);
    switch (id) {
      case 'apple_pay':
        return 'Apple Pay';
      case 'google_pay':
        return 'Google Pay';
      case 'tap_to_pay':
        return 'Tap to Pay';
      case 'credit_card':
        if (_savedCardLast4 != null && _savedCardBrand != null) {
          return '${_capitalizedBrand(_savedCardBrand)} •••• $_savedCardLast4';
        }
        return loc.creditOrDebitCard;
      case 'paypal':
        return 'PayPal';
      case 'bank_account':
        return _savedBankLast4 != null
            ? 'Bank •••• $_savedBankLast4'
            : 'Bank Account';
      case 'test_mode':
        return loc.testModeLabel;
      default:
        return AppPlatform.isIOS ? 'Apple Pay' : 'Google Pay';
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
    _cancelDialogShown = false;
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
    // Release payment hold if one was created
    final intentId = _heldPaymentIntentId;
    if (intentId != null) {
      _heldPaymentIntentId = null;
      unawaited(ApiService.cancelPaymentIntent(intentId));
    }
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
    // Reset ALL cinematic state so the next route can animate fresh
    _showPinLabels = false;
    _labelsRevealed = false;
    _cinematicRunning = false;
    _cinematicDone = false;
    _placingMarkers = false;
    // Reset floating label state so labels position correctly next time
    _pickupScreenOffset = null;
    _dropoffScreenOffset = null;
    _pickupLabelRevealed = false;
    _dropoffLabelRevealed = false;
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
