part of 'ride_request_screen.dart';

// ════════════════════════════════════════════════════════════
//  CONTROLLER — payment, search, scheduling
// ════════════════════════════════════════════════════════════

final _last4Re = RegExp(r'(\d{4})$');

extension _RideRequestController on _RideRequestScreenState {

  // `Navigator.of` ends in `return navigator!` and `ScaffoldMessenger.of` in
  // `dependOnInheritedWidgetOfExactType<_ScaffoldMessengerScope>()!`. The
  // assert that explains the mistake is compiled out of release, so a context
  // whose element is DEACTIVATED — the route is mid-pop while a cancel or
  // payment callback is still running, and `mounted` is still true because
  // dispose() has not run yet — makes the lookup return null and the `!`
  // throw "Null check operator used on a null value". Both statics are small
  // enough for AOT to inline, so Crashlytics blamed this file instead of the
  // framework (iOS 1.0.9+542, cancel + payment flows).
  //
  // Every navigation and snackbar here goes through these: on a dead context
  // the call becomes the no-op it already was semantically.
  NavigatorState? get _nav => mounted ? Navigator.maybeOf(context) : null;
  NavigatorState? get _rootNav =>
      mounted ? Navigator.maybeOf(context, rootNavigator: true) : null;
  ScaffoldMessengerState? get _messenger =>
      mounted ? ScaffoldMessenger.maybeOf(context) : null;

  /// Shows an error SnackBar with a Retry action button (8-second duration).
  void _showRetrySnackBar(String message, VoidCallback onRetry) {
    _messenger?.showSnackBar(
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
            onPressed: () => Navigator.maybeOf(ctx)?.pop(),
            child: Text(
              s.cancel,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.maybeOf(ctx)?.pop();
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
    if (kIsWeb) {
      // Same glide in the browser — _mapCtrl is null there and the camera
      // used to just sit still until the route fit arrived.
      _webAutoCameraUntil =
          DateTime.now().add(const Duration(milliseconds: 1050));
      _webMapCtrl?.flyTo(
        lng: target.longitude,
        lat: target.latitude,
        zoom: 16.5,
        durationMs: 800,
      );
      return;
    }
    _mapCtrl?.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(coordinates: mapbox.Position(target.longitude, target.latitude)),
        zoom: 16.5,
      ),
      mapbox.MapAnimationOptions(duration: 800),
    ).catchError((Object _) {});
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
          // add, don't replace. This was `= {'credit_card'}`, which wiped
          // the 'bank_account' entry added a few lines above in this same
          // function. A rider with both a linked bank and a card could
          // select the bank — the label even showed its last 4 digits,
          // since that is a separate field — but Request Ride stayed
          // disabled, because _hasAnyPaymentMethod looks for the entry
          // this line had just deleted. Only bit riders who had both.
          _linkedPaymentMethods.add('credit_card');
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

  /// Whether the GPS resolution in [_initLocation] is allowed to move the
  /// camera. It resolves the rider's own position, which is only ever a
  /// sensible place to point the map at when nothing else owns the frame.
  ///
  /// Never during the pin-drop picker. The rider is choosing a point that by
  /// definition is not where they are standing, and the screen was handed a
  /// handoff camera to boot at — so flying to their GPS there is wrong every
  /// time, not just sometimes. `route == null` alone did not cover it: the
  /// route is still being fetched while the picker opens, so the guard was
  /// wide open, and the last-known fix lands within milliseconds. A rider who
  /// started dragging immediately had the map yanked back mid-gesture by a
  /// `setCamera` — instant, no animation, which is why it read as a snap.
  ///
  /// `widget.pickerMode` is checked as well as the phase because the phase is
  /// only set in a post-frame callback, and the last-known fix can beat it.
  ///
  /// `_mapMounted` closes the covered-screen case: a booking sheet sitting
  /// UNDER the picker has no live surface (the coordinator revoked it), so
  /// a fix landing then must not write a camera — the rider is dragging the
  /// picker's map on top, and a covered sheet's top-down GPS flyTo is the
  /// snap-back they feel. While the surface is ours the term is a no-op.
  bool get _gpsMayMoveCamera {
    // Picker mode is a deliberate pin-drop UX: the camera must stay on the
    // handoff seed (selected address), never fly to the rider's live GPS.
    // Hard return so a single miss anywhere else in the expression cannot
    // accidentally allow a GPS move during picking.
    if (widget.pickerMode) {
      return false;
    }
    final allowed = _mapMounted &&
        _ctrl.state.phase != RiderPhase.pickingLocation &&
        _ctrl.state.route == null &&
        !_userTookCamera;
    // Instrumented because the rider still reports the picker camera
    // snapping back on a build that HAS this guard. If a reproduction shows
    // no line from here, the mover is not _initLocation and the hunt goes
    // elsewhere; if it shows one, the guard is being defeated and this says
    // by which term.
    if (allowed && _ctrl.state.phase == RiderPhase.pickingLocation) {
      debugPrint('[RideRequest] GPS camera move ALLOWED during picker — '
          'pickerMode=${widget.pickerMode} phase=${_ctrl.state.phase} '
          'route=${_ctrl.state.route != null} took=$_userTookCamera');
    }
    return allowed;
  }

  Future<void> _initLocation() async {
    try {
      // The empty booking sheet starts here.
      //
      // On web, getCurrentPosition IS the permission prompt: the browser's
      // Geolocation API resolves with a real fix or rejects when the rider
      // denies, while requestPermission() can hang forever. This used to
      // skip GPS entirely and seed downtown Birmingham — so the pickup was
      // always "601 19th Street North" no matter where the rider was, and
      // every route preview started from the wrong city.
      //
      // Null _userLocation is not cosmetic. _userLocation is the only source
      // a pickup ever gets when the rider did not search one by name, and
      // _tryFetchRoute() returns early on `pickup == null` — so rideOptions
      // is never filled and the sheet keeps its four shimmer cards forever.
      // If the real fix fails we fall back to the last cached fix, then to
      // the seed — logging which path was taken instead of teleporting the
      // pickup silently.
      if (kIsWeb) {
        LatLng? fix;
        try {
          // The Dart-side .timeout is NOT redundant with timeLimit:
          // geolocator's web implementation does not enforce timeLimit, so
          // a browser that grants the permission but never produces a
          // position left this await hanging FOREVER — _userLocation stayed
          // null, and the picker's Confirm waited its full 12 s on
          // _locationReadyFuture and then bounced the rider out of the
          // picker with a Navigator.pop. Caught live on 2026-08-04.
          final pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 10),
            ),
          ).timeout(const Duration(seconds: 8));
          fix = LatLng(pos.latitude, pos.longitude);
          debugPrint('[RideRequest] web GPS: real browser fix '
              '${fix.latitude},${fix.longitude}');
        } catch (e) {
          debugPrint('[RideRequest] web GPS denied/unavailable: $e');
          final lat = LocalCache.get<double>('last_driver_lat');
          final lng = LocalCache.get<double>('last_driver_lng');
          if (lat != null && lng != null) {
            fix = LatLng(lat, lng);
            debugPrint('[RideRequest] web GPS: cached fix $lat,$lng');
          }
        }
        // Same downtown Birmingham seed the driver screens already use —
        // last resort only, so the sheet can still function.
        if (fix == null) {
          debugPrint('[RideRequest] web GPS: no real or cached fix — '
              'Birmingham seed fallback');
        }
        final center = fix ?? const LatLng(33.5186, -86.8104);
        if (!mounted) return;
        _setState(() {
          _userLocation = center;
          _center = center;
          _fetchingLocation = false;
        });
        // Browser geolocation can take seconds (permission prompt) — by
        // then the route may already be framed, and this late flight would
        // yank the camera off it. Also mark the move as ours: unmarked it
        // used to read as a rider pan and disable every later auto-frame.
        if (_gpsMayMoveCamera) {
          _webAutoCameraUntil =
              DateTime.now().add(const Duration(milliseconds: 1050));
          _webMapCtrl?.flyTo(
              lng: center.longitude, lat: center.latitude, zoom: 15.5,
              durationMs: 800);
          // Was outside the guard entirely. Harmless only by accident —
          // _mapCtrl is null on web, so it never fired here — but it is the
          // same unconditional teleport the guard above exists to prevent.
          _mapCtrl?.setCamera(mapbox.CameraOptions(
            center: mapbox.Point(
              coordinates: mapbox.Position(center.longitude, center.latitude),
            ),
            zoom: 15.5,
          )).catchError((Object _) {});
        }
        // Reverse geocode the fix so the pickup label isn't a lie — the
        // seed path keeps the sheet's default label instead.
        if (fix != null) {
          final places = PlacesService(ApiKeys.webServices);
          final addr = await places.reverseGeocode(
            lat: fix.latitude,
            lng: fix.longitude,
          );
          if (addr != null && mounted) {
            _setState(() => _currentAddress = addr);
          }
        }
        return;
      }
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
                  onPressed: () => Navigator.maybeOf(ctx)?.pop(),
                  child: Text(S.of(ctx).cancel),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.maybeOf(ctx)?.pop();
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
          // Same guard the web branch carries: with a route on screen the
          // camera belongs to the cinematic/route frame, and once the rider
          // moved the map (picker drag included) it belongs to them. This
          // unguarded write used to teleport the camera back to the rider
          // whenever the last-known fix landed between cinematic ticks.
          //
          // This is the one the rider felt in the drop-off picker: cached, so
          // it answers in milliseconds, and instant, so it does not glide —
          // it snaps.
          if (_gpsMayMoveCamera) {
            debugPrint('[CamSnap] GPS last-known setCamera -> user location');
            // Same channel-error release as _pushCamera (:1145): a rejected
            // setCamera means the surface is gone, and nulling the handle is
            // what stops every later write at the first failure.
            final mc = _mapCtrl;
            if (mc != null) {
              mc.setCamera(mapbox.CameraOptions(
                center: mapbox.Point(coordinates: mapbox.Position(lastLl.longitude, lastLl.latitude)),
                zoom: 15.5,
              )).catchError((Object e) {
                if (identical(_mapCtrl, mc) &&
                    e is PlatformException &&
                    e.code == 'channel-error') {
                  _mapCtrl = null;
                }
              });
            }
          }
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
      // A cold high-accuracy fix can take up to 10 s: by then the cinematic
      // may be flying (this flyTo fought it frame-by-frame) or already
      // settled on the route frame (this abandoned it and glided to the
      // pickup at street zoom — the "animation destroyed, map parked at the
      // pickup" report). Same rule as above and as the web branch.
      if (_gpsMayMoveCamera) {
        debugPrint('[CamSnap] GPS fresh-fix flyTo -> user location');
        _mapCtrl?.flyTo(
          mapbox.CameraOptions(center: mapbox.Point(coordinates: mapbox.Position(ll.longitude, ll.latitude)), zoom: 15.5),
          mapbox.MapAnimationOptions(duration: 800),
        ).catchError((Object _) {});
      }

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

          if (kIsWeb) {
            // Native draws via the cinematic; the browser map gets its
            // polyline + endpoint pins pushed directly.
            unawaited(_drawWebRouteOnce());
          } else if (!_cinematicDone && !_cinematicRunning) {
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
        // Keep the availability answers fresh while the sheet is open —
        // a driver coming online must clear "No drivers" by itself.
        _startWaitRefresh();
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
            // Collapsed *before* the option is set, so the first frame that
            // has a tier already has it open.
            //
            // This used to collapse in a post-frame callback, which meant
            // one frame of the four-up grid and then a 680 ms open — the
            // rider watching the app re-stage a choice they had already
            // made on the home screen. They picked the tier there; the
            // picker should not ask again on the way past.
            _gridExpanded = false;
            _ctrl.selectRideOption(match);
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
          // cadence so the message cycles identically. The camera does NOT
          // cycle with it: re-flying to the same fixed frame on every tick
          // restarted the animation all through the search and fought the
          // rider's finger whenever they panned to read the route.
          _searchStatusTimer = Timer.periodic(const Duration(milliseconds: 3500), (_) {
            if (mounted) {
              _setState(() => _searchStatusIdx++);
            }
          });
          _searchElapsedTimer?.cancel();
          _searchElapsedTimer = Timer.periodic(const Duration(seconds: 2), (_) {
            if (mounted) _setState(() => _searchElapsedSec += 2);
          });
          // Force immediate rebuild so bottom card shows right away (no black flash)
          _setState(() => _searchingShowMap = true);
          // The request is in — availability answers no longer matter here.
          _waitRefreshTimer?.cancel();
          _waitRefreshTimer = null;
          // Trigger cinematic sequence on searching phase open
          _replayCinematicIfRouteAvailable();
          // Entering the search is an explicit auto-frame moment: clear
          // the rider-took-camera latch or a pan made while choosing a
          // vehicle leaves the route half off-screen for the whole search
          // (user report 2026-08-04). They can still pan afterwards —
          // the latch re-arms on the next gesture.
          _userTookCamera = false;
          // Frame the full route ONCE for the search, then hold it.
          _animateSearchCameraToAngle(0);
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
          // The overlay no longer mounts its own map (that was the black
          // screen) — the LIVE main map glides to the route midpoint with
          // the 20° tilt instead, one flight doing what the old per-frame
          // tilt controller did.
          _dfFlyMainCamera();
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
            _nav?.pushAndRemoveUntil(
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
            _nav?.pushAndRemoveUntil(
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
          final cancelNav = _rootNav;
          if (cancelNav == null) return;
          showDialog(
            context: cancelNav.context,
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
                    Navigator.maybeOf(dialogCtx)?.pop();
                    _ctrl.reset();
                    if (mounted) {
                      _nav?.pushAndRemoveUntil(
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
    final nav = _nav;
    if (nav == null) return;
    final result = await nav.push<Map<String, dynamic>>(
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
        final screenH = (MediaQuery.maybeOf(context)?.size.height ?? 800.0);
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
                        Navigator.maybeOf(ctx)?.pop();
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
    // Resolved before the re-entrancy guard, never between it and
    // _rideFlowLocked: an await in that gap spans event-loop turns while the
    // lock still reads false, so a second tap walks straight into the charge.
    final bool isTestMode = await _isTestModeActive();
    if (!mounted) return;

    if (_rideFlowLocked || _isProcessingPayment) return;

    // Validate payment method exists before proceeding
    if (!_hasAnyPaymentMethod && !isTestMode) {
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
        _nav?.pop(); // close payment modal
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
      _nav?.pop();
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

    // Resolved once, and before the re-entrancy guard below — never between
    // that guard and _rideFlowLocked. An await in that gap spans event-loop
    // turns while the lock still reads false, so a second tap walks straight
    // into the charge. Every branch further down that skips the charge reads
    // this same answer instead of re-testing the selected id.
    final bool isTestMode = await _isTestModeActive();
    if (!mounted) return;

    if (_rideFlowLocked || _isProcessingPayment) return;

    // Validate payment method exists before proceeding
    if (!_hasAnyPaymentMethod && !isTestMode) {
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
      final nav = _nav;
      if (nav == null) return;

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
          _nav?.pushAndRemoveUntil(
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
            cancelCode == RiderTripCancelCodes.clientConnectionError ||
            cancelCode == RiderTripCancelCodes.clientPaymentDeclined;
        if (isClientError) {
          _ctrl.reset();
          // 402 declines carry the stringified backend detail as rawReason —
          // show the localized decline message instead of the raw payload.
          final msg = cancelCode == RiderTripCancelCodes.clientPaymentDeclined
              ? S.of(context).cancelCodeMessage(cancelCode, rawReason: rawReason)
              : (rawReason ?? S.of(context).tripCancelled);
          _messenger?.showSnackBar(
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
          _nav?.pushAndRemoveUntil(
            smoothFadeRoute(const HomeScreen()),
            (_) => false,
          );
          return;
        }
        _nav?.pushAndRemoveUntil(
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
          final rootNav = _rootNav;
          if (rootNav == null) return;
          showDialog(
            context: rootNav.context,
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
              actions: [TextButton(onPressed: () => Navigator.maybeOf(dialogCtx)?.pop(), child: Text(S.of(context).okBtn))],
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
        final navRoot = _rootNav;
        _nav?.pushAndRemoveUntil(
          smoothFadeRoute(const HomeScreen()),
          (_) => false,
        );
        // Show dialog on home screen after a short delay
        Future.delayed(const Duration(milliseconds: 600), () {
          if (navRoot == null || !navRoot.mounted) return;
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
                  onPressed: () => Navigator.maybeOf(dialogCtx)?.pop(),
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
    // flutter_stripe has no web implementation — reading Stripe.instance
    // throws. Report success so the browser build can walk the rest of
    // the flow; nothing is charged and no native sheet exists to open.
    if (kIsWeb) return true;

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
      case 'bank_account':
        // ACH debit against the linked bank account. Without this case the
        // switch fell to `default` → false, which _startRideRequest reads as
        // "rider dismissed the OS sheet": tapping Request Ride with the bank
        // selected did nothing at all — no trip, no charge, no error.
        return _confirmBankAccount(amountCents, option);
      case 'cruise_cash':
        // Fully covered by the balance — no hold to place; the backend
        // debits Cruise Cash at dispatch (apply_cruise_cash_to_fare).
        // The Request button is disabled while the balance falls short
        // (_cruiseCashShort), so false here only guards a race where the
        // balance changed under us.
        return Future.value(_cruiseCashCents >= amountCents);
      default:
        // Unrecognised payment method — never allow payment to proceed silently.
        debugPrint('[Payment] _confirmNativePayment: unknown method "$_selectedPaymentMethod"');
        return false;
    }
  }

  /// Apple Pay: present native Apple Pay sheet via Stripe (hold only).
  Future<bool> _confirmApplePay(int amountCents, String label) async {
    // flutter_stripe has no web implementation — reading Stripe.instance
    // throws. Report success so the browser build can walk the rest of
    // the flow; nothing is charged and no native sheet exists to open.
    if (kIsWeb) return true;

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
    // flutter_stripe has no web implementation — reading Stripe.instance
    // throws. Report success so the browser build can walk the rest of
    // the flow; nothing is charged and no native sheet exists to open.
    if (kIsWeb) return true;

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
    // flutter_stripe has no web implementation — reading Stripe.instance
    // throws. Report success so the browser build can walk the rest of
    // the flow; nothing is charged and no native sheet exists to open.
    if (kIsWeb) return true;

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
      final nav = _nav;
      if (nav == null) return false;
      result = await nav.push<bool>(
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
    // flutter_stripe has no web implementation — reading Stripe.instance
    // throws. Report success so the browser build can walk the rest of
    // the flow; nothing is charged and no native sheet exists to open.
    if (kIsWeb) return true;

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

      // Confirmed server-side. 'processing' IS the success state for ACH —
      // Stripe settles the debit over the next few business days.
      if (status == 'succeeded' ||
          status == 'requires_capture' ||
          status == 'processing') {
        return true;
      }

      // Anything else is a real failure and must NOT dispatch a driver:
      //   requires_payment_method → the debit was rejected outright
      //   requires_action         → Stripe wants microdeposit verification
      //   canceled                → intent died server-side
      // The old code had an unconditional `return true` here, so both of
      // those shipped a free ride. Throw instead so _handlePaymentFailure
      // can offer the rider another method.
      debugPrint('[Bank] unexpected PaymentIntent status: $status');
      _heldPaymentIntentId = null;
      throw ApiException(402, 'ach_not_confirmed:${status ?? 'unknown'}');
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
        _messenger?.showSnackBar(
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
        _messenger?.showSnackBar(
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
        _messenger?.showSnackBar(
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
        _messenger?.showSnackBar(
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
        // Hold placed by _confirmNativePayment before we got here (skipped
        // in test mode) — the backend captures/cancels it with the trip.
        paymentIntentId: _heldPaymentIntentId,
      );

      if (!mounted) return;

      // Navigate to animated confirmation screen
      HapticService.heavyImpact();
      _nav?.pushAndRemoveUntil(
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
      // Backend rejected the hold (402 missing/failed PaymentIntent) — show
      // the same payment-declined dialog as the immediate flow instead of
      // the generic schedule retry; the reservation was NOT created.
      if (e is ApiException && e.statusCode == 402) {
        final option = _ctrl.state.selectedOption;
        if (option == null) return;
        final amountCents = (option.priceEstimate * 100).round();
        await _handlePaymentFailure(
          error: e,
          amountCents: amountCents,
          originalMethod: _selectedPaymentMethod,
          option: option,
        );
        return;
      }
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
                  onPressed: () => Navigator.maybeOf(ctx)?.pop(),
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

  /// Driver Found: fit the WHOLE route once with the celebratory 20° tilt.
  /// Replaces the overlay's former private map — one surface, no black
  /// init window, no two-surface iOS crash. The old midpoint-at-14.5
  /// flight put both endpoints off-screen on longer trips. Driver
  /// location updates after this move the marker/ETA only, never the
  /// camera.
  void _dfFlyMainCamera() {
    // The rider's hand outranks this frame too — _safeFlyTo/_fitWebRoute
    // don't check the latch themselves, their callers do.
    if (_userTookCamera) return;
    final s = _ctrl.state;
    final pickup = s.pickup;
    final dropoff = s.dropoff;
    if (pickup == null) return;
    // Fit the route polyline; fall back to the two endpoints when the
    // route never landed.
    final routePts = s.route?.points ?? const <LatLng>[];
    final fitPts = routePts.isNotEmpty
        ? routePts
        : [
            LatLng(pickup.lat, pickup.lng),
            if (dropoff != null) LatLng(dropoff.lat, dropoff.lng),
          ];
    if (fitPts.length < 2) {
      // Pickup only — nothing to fit; keep the old single-point frame.
      if (kIsWeb) {
        _webMapCtrl?.flyTo(
            lng: pickup.lng, lat: pickup.lat, zoom: 14.5, pitch: 20, durationMs: 1000);
        return;
      }
      _safeFlyTo(
        mapbox.CameraOptions(
          center:
              mapbox.Point(coordinates: mapbox.Position(pickup.lng, pickup.lat)),
          zoom: 14.5,
          pitch: 20.0,
        ),
        mapbox.MapAnimationOptions(duration: 1000),
      );
      return;
    }
    if (kIsWeb) {
      // Browser twin of the fit below — same top inset, same tilt.
      _fitWebRoute(List<LatLng>.from(fitPts),
          durationMs: 1000, pitch: 20, paddingTop: 90);
      return;
    }
    final mc = _mapCtrl;
    if (mc == null) return;
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final p in fitPts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final mq = MediaQuery.maybeOf(context);
    if (mq == null) return;
    // Same sheet inset the searching frame uses, so the whole route
    // clears the Driver Found card.
    final bottomInset = _sheetHeightPx > 0
        ? _sheetHeightPx + 24 + 16
        : (mq.size.height * 0.38).clamp(280.0, 400.0) + mq.padding.bottom;
    mc
        .cameraForCoordinatesPadding(
      [
        mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
        mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat)),
      ],
      mapbox.CameraOptions(pitch: 20.0),
      mapbox.MbxEdgeInsets(top: 90, left: 50, bottom: bottomInset, right: 50),
      null,
      null,
    )
        .then((cam) {
      // Gated like every other fit — _safeFlyTo validates cam before the
      // channel write (see _animateSearchCameraToAngle).
      _safeFlyTo(
        mapbox.CameraOptions(
          center: cam.center,
          zoom: cam.zoom,
          pitch: 20.0,
        ),
        mapbox.MapAnimationOptions(duration: 1000),
      );
    }).catchError((e) {
      debugPrint('[DriverFound] fit full route failed: $e');
    });
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
      // Test Mode is for App Review only (user spec 2026-08-06). It used
      // to be in every rider's picker — a tile that completes a ride
      // without charging anything, one tap away for anyone.
      showTestMode: _testModeAllowed,
    );
    // The sheet's Cruise Balance toggle may have changed — refresh the
    // discount preview either way before reading the result.
    unawaited(_loadCruiseCashBalance());
    if (picked == null || !mounted) return;

    // Refresh the linked-methods set from prefs BEFORE the contains()
    // check below: a card added inside the sheet wrote
    // linkPaymentMethod('credit_card') to storage, but this in-memory set
    // was loaded at screen init — stale, it bounced the rider into the
    // full-screen CreditCardScreen right after a successful in-sheet add
    // (duplicate SetupIntent on the same card). Prefs only, deliberately
    // NOT _loadLinkedPayments(): its backend restore could clobber the
    // just-saved default with a 30s-stale cached response.
    final linkedNow = await LocalDataService.getLinkedPaymentMethods();
    final cardLast4 = await LocalDataService.getCreditCardLast4();
    final cardBrand = await LocalDataService.getCreditCardBrand();
    if (!mounted) return;
    _setState(() {
      _linkedPaymentMethods = linkedNow;
      _savedCardLast4 = cardLast4;
      _savedCardBrand = cardBrand;
    });

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
    final isTestMode = await _isTestModeActive();
    if (!mounted) return false;
    if (isTestMode) return true;
    if (_selectedPaymentMethod == 'cruise_cash') {
      // No hold/charge at request time — the backend debits the balance
      // at dispatch. Full coverage was checked at the Request button;
      // re-check defensively in case the balance moved.
      return _cruiseCashCents >= amountCents;
    }
    
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
      if (_testModeAllowed) ('test_mode', 'Test Mode', true),
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
                            Navigator.maybeOf(ctx)?.pop();
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
                    Navigator.maybeOf(ctx)?.pop();
                    await _nav?.push(slideFromRightRoute(const PaymentAccountsScreen()));
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
    final result = await _nav?.push<String>(slideFromRightRoute(const CreditCardScreen()));
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
    await _nav?.push(slideFromRightRoute(const PaymentAccountsScreen()));
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
      // Test Mode moves no money, so it counts as a method only for the one
      // account allowed to use it — otherwise a stale selection enables
      // Request Ride for a rider who has nothing on file.
      case 'test_mode':
        return _testModeAllowed;
      case 'paypal':
      case 'apple_pay':
      case 'google_pay':
      case 'tap_to_pay':
      // Whether the balance actually covers the fare is a separate gate
      // on the Request button (_cruiseCashShort) — the method itself is
      // always "present".
      case 'cruise_cash':
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
      case 'cruise_cash':
        return '${loc.cruiseCash} — \$${(_cruiseCashCents / 100.0).toStringAsFixed(2)}';
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

  Future<void> _cancelSearching() async {
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
    // Awaited before reset(): reset() clears the trip id, and cancelRide needs
    // it to reach the backend. Firing both together left the trip `requested`
    // on the server whenever the request lost the race, so the next launch
    // restored the ride the rider had just cancelled.
    await _ctrl.cancelRide();
    _ctrl.reset();
    _navigatingToTracking = false;
  }

  /// Starts the 20-second availability refresh (idempotent) while the
  /// booking sheet is on screen.
  void _startWaitRefresh() {
    if (_waitRefreshTimer != null) return;
    _waitRefreshTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => unawaited(_refreshWaitEstimates()),
    );
  }

  /// Re-asks how many drivers are around the pickup — the untiered key
  /// that drives the "No drivers" gate and the big wait figure, plus each
  /// tier card's own range — then repaints so a driver who just came
  /// online clears the notice without an app restart.
  Future<void> _refreshWaitEstimates() async {
    final p = _ctrl.state.pickup;
    if (p == null || !mounted) return;
    await Future.wait([
      DriverWaitEstimate.fetch(lat: p.lat, lng: p.lng, force: true),
      for (final t in const ['black', 'premium', 'compact', 'standard'])
        DriverWaitEstimate.fetch(lat: p.lat, lng: p.lng, tier: t, force: true),
    ]);
    if (mounted) _setState(() {});
  }

  /// Removes all trip-related polyline and pin annotations from the map.
  Future<void> _cleanupMapAnnotations() async {
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = null;
    _webRouteAnimTimer?.cancel();
    _webRouteAnimTimer = null;
    // Web overlays live on the browser controller, not the native
    // annotation managers — clear them too or the old route survives
    // into the next search.
    final web = _webMapCtrl;
    if (web != null) {
      // The WebMapView can be unmounted (driver-found swap, tracking
      // handoff) while this handle still points at the disposed GL JS map;
      // a throw here used to abort the cleanup below it.
      try {
        web.removePolyline('route');
        web.removeMarker('pickup');
        web.removeMarker('dropoff');
      } catch (_) {}
    }
    _webRouteDrawn = false;
    _webRouteLineDrawn = false;
    _webRouteSig = 0;
    _webRouteAnimTimer?.cancel();
    // The sheet unmounts with the phase change; the next one re-measures.
    _sheetHeightPx = 0;
    _sheetFitDebounce?.cancel();
    _userTookCamera = false;
    _waitRefreshTimer?.cancel();
    _waitRefreshTimer = null;
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
    // Reset ALL cinematic state so the next route can animate fresh.
    // Bump the token FIRST and stop the tilt: a cinematic still flying
    // would keep writing setCamera per frame toward the dead trip for up
    // to 2 s, and its tail would re-write _cinematicDone = true over this
    // reset — the "next ride never animates" bug.
    _cinematicGen++;
    _tiltCtrl?.stop();
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
    const gold = Color(0xFFE8C547);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 20),
          decoration: neuBox(radius: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: neuBox(radius: 18, pressed: true),
                child: const Icon(
                  Icons.cancel_outlined,
                  color: gold,
                  size: 28,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                S.of(context).cancelRideQuestion,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                S.of(context).cancelRideMsg,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.maybeOf(ctx)?.pop(),
                      child: Container(
                        height: 48,
                        alignment: Alignment.center,
                        decoration: neuBox(radius: 12, pressed: true),
                        child: Text(
                          S.of(context).keepWaiting,
                          style: const TextStyle(
                            color: gold,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        Navigator.maybeOf(ctx)?.pop();
                        _cancelSearching();
                        // Navigate to home screen with fade transition
                        if (mounted) {
                          _nav?.pushAndRemoveUntil(
                            smoothFadeRoute(const HomeScreen()),
                            (_) => false,
                          );
                        }
                      },
                      child: Container(
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: gold,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          S.of(context).yesCancelBtn,
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
