part of 'map_screen.dart';

// ════════════════════════════════════════════════════════════
//  MAP — annotations, camera, routes, animations
// ════════════════════════════════════════════════════════════

extension _MapScreenMap on _MapScreenState {

  /// Builds a circular pin using the unified circular_pin_renderer.
  Future<Uint8List> _buildGoldPin({
    bool withHouse = false,
    bool isPickup = true,
  }) async {
    return renderCircularPinBytes(
      icon: withHouse ? CircularPinIcon.home : CircularPinIcon.dot,
      isPickup: isPickup,
      radius: 32,
    );
  }

  /// Golden teardrop pin for route endpoints.
  /// Uses iconAnchor.BOTTOM so the pin tip sits exactly on the coordinate.
  Future<Uint8List> _buildRouteDotPin({required bool isPickup}) async {
    return renderCircularPinBytes(
      icon: isPickup ? CircularPinIcon.person : CircularPinIcon.home,
      isPickup: isPickup,
      radius: 44,
    );
  }

  void _onCameraMove(LatLng position) {
    _cameraTarget = position;
    // Any manual gesture resets the zoom toggle so next tap centers first.
    if (!_isRecentering) _isCenteredOnPickup = false;
  }

  void _onCameraIdle() {
    if (_isResolvingLocation) return;
    if (_stage == RideStage.confirmPickup) {
      _isRecentering = false;
      return; // pickup is a real marker now, not screen-center
    }
    if (_stage != RideStage.pin) return;
    if (_hasPreparedRoute && _dropoffPosition != null) return;
    final target = _cameraTarget;
    if (target == null) return;

    _cameraIdleDebounce?.cancel();
    _cameraIdleDebounce = Timer(const Duration(milliseconds: 150), () async {
      if (!mounted || _stage != RideStage.pin) return;

      final last = _lastReverseGeocodedTarget;
      if (last != null) {
        final movedMeters = Geolocator.distanceBetween(
          last.latitude,
          last.longitude,
          target.latitude,
          target.longitude,
        );
        if (movedMeters < 25) {
          return;
        }
      }

      if (_currentPosition != null) {
        final markerDistance = Geolocator.distanceBetween(
          _currentPosition!.latitude,
          _currentPosition!.longitude,
          target.latitude,
          target.longitude,
        );
        if (markerDistance < 2) {
          return;
        }
      }

      _setState(() {
        _tripMiles = '-- mi';
        _tripDuration = '-- min';
        _clearRouteAnnotation();
        _hasPreparedRoute = false;
      });

      final requestTicket = ++_reverseGeocodeTicket;
      try {
        final address = await _places.reverseGeocode(
          lat: target.latitude,
          lng: target.longitude,
        );
        if (!mounted || requestTicket != _reverseGeocodeTicket) return;
        final resolved = (address == null || address.isEmpty)
            ? _coordinatesLabel(target)
            : address;
        _lastReverseGeocodedTarget = target;
        _setState(() {
          _pickupAddress = resolved;
          _pickupCtrl.text = resolved;
          _setPickupAnnotation(target);
        });
      } catch (_) {
        if (!mounted || requestTicket != _reverseGeocodeTicket) return;
        final fallback = _coordinatesLabel(target);
        _setState(() {
          _pickupAddress = fallback;
          _pickupCtrl.text = fallback;
          _setPickupAnnotation(target);
        });
      }
    });
  }

  Future<void> _onMapCreated(mapbox.MapboxMap controller) async {
    _mapController = controller;
    // Hide scale bar, compass and Mapbox logo ornaments completely
    controller.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
    controller.compass.updateSettings(mapbox.CompassSettings(enabled: false));
    controller.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
    controller.logo.updateSettings(mapbox.LogoSettings(enabled: false));
    // Route polyline goes below all symbols/labels (at the very bottom)
    _polylineAnnotMgr = await controller.annotations.createPolylineAnnotationManager(
      below: "road-label",
    );
    // Points (car + pins) always above the route polyline and labels
    _pointAnnotMgr = await controller.annotations.createPointAnnotationManager(
      below: null, // No "below" constraint means it renders above everything
    );
    try {
      final lid = _pointAnnotMgr!.id;
      await controller.style.setStyleLayerProperty(lid, 'icon-pitch-alignment', 'viewport');
      await controller.style.setStyleLayerProperty(lid, 'icon-rotation-alignment', 'viewport');
      await controller.style.setStyleLayerProperty(lid, 'icon-anchor', 'bottom');
      await controller.style.setStyleLayerProperty(lid, 'icon-allow-overlap', true);
      await controller.style.setStyleLayerProperty(lid, 'icon-ignore-placement', true);
    } catch (_) {}
    if (_currentPosition != null) {
      _centerMapOn(_currentPosition!, zoom: _defaultMapZoom);
      await _setPickupAnnotation(_currentPosition!);
    }
    // Apply dark navy + gold road theme
  }

  void _onStyleLoaded(mapbox.StyleLoadedEventData _) async {
    if (_mapController != null) {
      await _applyDarkNavyGoldTheme(_mapController!);
      if (_pointAnnotMgr != null) {
        try {
          final lid = _pointAnnotMgr!.id;
          await _mapController!.style.setStyleLayerProperty(lid, 'icon-pitch-alignment', 'viewport');
          await _mapController!.style.setStyleLayerProperty(lid, 'icon-rotation-alignment', 'viewport');
          await _mapController!.style.setStyleLayerProperty(lid, 'icon-anchor', 'bottom');
          await _mapController!.style.setStyleLayerProperty(lid, 'icon-allow-overlap', true);
          await _mapController!.style.setStyleLayerProperty(lid, 'icon-ignore-placement', true);
        } catch (_) {}
      }
    }
  }

  /// Paints the map with a dark navy blue background and gold freeways/roads.
  /// Uses setStyleLayerProperty to override paint on the navigation-night-v1 layers.
  Future<void> _applyDarkNavyGoldTheme(mapbox.MapboxMap ctrl) async {
    await MapTheme.applyNavyGold(ctrl);
  }

  // ── Platform-aware camera helpers ─────────────────────────────────────

  /// Pan the camera to [target] with optional zoom/bearing/tilt.
  /// Works for both Google Maps (Android) and Apple Maps (iOS).
  Future<void> _panTo(
    LatLng target, {
    double? zoom,
    double bearing = 0,
    double tilt = 0,
  }) async {
    final z = zoom ?? _defaultMapZoom;
    _mapController?.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(coordinates: mapbox.Position(target.longitude, target.latitude)),
        zoom: z,
        bearing: bearing,
        pitch: tilt,
      ),
      mapbox.MapAnimationOptions(duration: 600),
    );
  }

  /// Fit the camera with independent insets per edge.
  Future<void> _fitBoundsInsets(
    List<LatLng> points,
    double top, double left, double bottom, double right,
  ) async {
    if (_mapController == null || points.isEmpty) return;
    final coords = points
        .map((p) => mapbox.Point(coordinates: mapbox.Position(p.longitude, p.latitude)))
        .toList();
    final cam = await _mapController!.cameraForCoordinatesPadding(
      coords,
      mapbox.CameraOptions(bearing: _cinematicBearing, pitch: _cinematicPitch),
      mapbox.MbxEdgeInsets(top: top, left: left, bottom: bottom, right: right),
      null, null,
    );
    if (mounted) _mapController?.flyTo(cam, mapbox.MapAnimationOptions(duration: 700));
  }

  /// Fit the FULL route (pickup â†’ dropoff) so both endpoints are visible
  /// with comfortable padding. Used when rider dismisses the arrived overlay.
  Future<void> _fitFullRouteVisible() async {
    if (_mapController == null) return;
    final points = <LatLng>[];
    if (_currentPosition != null) points.add(_currentPosition!);
    if (_dropoffPosition != null) points.add(_dropoffPosition!);
    if (points.length < 2) return;

    final coords = points
        .map((p) => mapbox.Point(coordinates: mapbox.Position(p.longitude, p.latitude)))
        .toList();

    final media = MediaQuery.of(context);
    final topInset = media.padding.top + 100; // space for driver info card
    final bottomInset = media.padding.bottom + 80; // space for bottom bar

    final cam = await _mapController!.cameraForCoordinatesPadding(
      coords,
      mapbox.CameraOptions(bearing: 0, pitch: 0),
      mapbox.MbxEdgeInsets(
        top: topInset,
        left: 40,
        bottom: bottomInset,
        right: 40,
      ),
      null, null,
    );
    if (mounted) {
      _mapController?.flyTo(cam, mapbox.MapAnimationOptions(duration: 800));
    }
  }

  /// Returns the bottom pixel inset to account for the bottom panel height.
  double _panelBottomInset() {
    switch (_stage) {
      case RideStage.options:
        return 420.0;
      case RideStage.payment:
      case RideStage.confirmPickup:
        return 300.0;
      case RideStage.matching:
      case RideStage.riding:
        return 280.0;
      default:
        return 80.0;
    }
  }

  Future<void> _centerMapOn(LatLng target, {double zoom = 15.5}) async {
    if (!_hasMapController) return;
    await _smoothCameraTransition(target, zoom);
  }

  void _onCameraMoveStarted() {
    // User panned — could pause auto-follow here if needed
  }

  double _routeVerticalShiftFactor() {
    switch (_stage) {
      case RideStage.options:
        return 0.16;
      case RideStage.loading:
        return 0.14;
      case RideStage.confirmPickup:
        return 0.12;
      case RideStage.payment:
        return 0.14;
      case RideStage.matching:
        return 0.15;
      case RideStage.riding:
        return 0.15;
      case RideStage.plan:
        return 0.1;
      case RideStage.pin:
        return 0.0;
    }
  }

  void _applyCinematicCamera() {
    if (_mapController == null || !mounted) return;
    _mapController!.setCamera(mapbox.CameraOptions(
      pitch: _tiltAnim?.value,
      bearing: _bearingAnim?.value,
    ));
  }

  void _startPinPop() {
    _pinPopCtrl?.dispose();
    _pinPopCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _pinPopAnim = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.01, end: 1.15).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 60,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.15, end: 0.95).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 20,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 0.95, end: 1.0).chain(CurveTween(curve: Curves.elasticOut)),
        weight: 20,
      ),
    ]).animate(_pinPopCtrl!);
    _pinPopAnim!.addListener(_updatePinScales);
    // Shrink pins before pop
    _setPinScale(0.01);
    _pinPopCtrl!.forward(from: 0);
  }

  void _updatePinScales() {
    final s = _pinPopAnim?.value ?? 1.0;
    _setPinScale(s);
  }

  void _setPinScale(double s) {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    if (_pickupAnnot != null) {
      _pickupAnnot!.iconSize = s;
      try { mgr.update(_pickupAnnot!); } catch (_) {}
    }
    if (_dropoffAnnot != null) {
      _dropoffAnnot!.iconSize = s;
      try { mgr.update(_dropoffAnnot!); } catch (_) {}
    }
  }

  void _startRouteShimmer() {
    _routeShimmerCtrl?.dispose();
    _routeShimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _routeShimmerCtrl!.addListener(_onRouteShimmerTick);
  }

  void _onRouteShimmerTick() {
    final mgr = _polylineAnnotMgr;
    final annot = _routeAnnot;
    if (mgr == null || annot == null) return;
    final v = _routeShimmerCtrl?.value ?? 0.0;
    // Pulse width between 5 and 7
    annot.lineWidth = 5.0 + v * 2.0;
    try { mgr.update(annot); } catch (_) {}
  }

  void _stopRouteShimmer() {
    _routeShimmerCtrl?.removeListener(_onRouteShimmerTick);
    _routeShimmerCtrl?.dispose();
    _routeShimmerCtrl = null;
  }

  /// Push a new raw GPS position from the backend poll into SmoothMotion.
  /// SmoothMotion lerps continuously at 60fps — no restarts, no jumps.
  void _animateDriverTo(LatLng newPos) {
    _prevDriverPosition = _driverPosition;

    // Snap to route so the car follows the road, not a straight line
    LatLng snapped = newPos;
    double bearing = _driverBearing;
    if (_driverRoutePoints.length >= 2) {
      final snap = RouteSnapper.snap(
        newPos,
        _driverRoutePoints,
        lastIndex: _driverSnapIdx,
      );
      _driverSnapIdx = snap.segmentIndex;
      snapped = snap.snapped;
      bearing = snap.bearingDeg;
    } else if (_prevDriverPosition != null) {
      final moved = Geolocator.distanceBetween(
        _prevDriverPosition!.latitude, _prevDriverPosition!.longitude,
        newPos.latitude, newPos.longitude,
      );
      if (moved > 2) bearing = _calcBearing(_prevDriverPosition!, newPos);
    }

    if (_driverMotion == null) return;
    // Teleport on first fix so the car appears immediately
    if (_driverPosition == null) {
      _driverMotion!.teleport(snapped, bearing);
      _driverPosition = snapped;
      _driverBearing = bearing;
    } else {
      _driverMotion!.pushTarget(snapped, bearing);
    }
  }

  /// Called every vsync frame by SmoothMotion — 60fps, butter smooth.
  void _onDriverMotionTick(LatLng pos, double bearing, double curveTilt) {
    if (!mounted) return;
    _driverPosition = pos;
    _driverBearing = bearing;

    // Update driver car marker position and rotation on the map
    _updateDriverCarMarker(pos, bearing);

    if (_stage == RideStage.riding && _driverPosition != null) {
      _panTo(_driverPosition!, zoom: 18.5, bearing: bearing, tilt: 0);
    }

    if (_driverRoutePoints.length > 2) {
      _trimRiderRoute(_driverPosition!);
    }
  }

  /// Creates or updates the driver car marker on the map.
  Future<void> _updateDriverCarMarker(LatLng pos, double bearing) async {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;

    if (_driverCarAnnot == null) {
      // First time — create the marker with a car icon
      try {
        final carBytes = await buildGoldenPinBytes(
          icon: Icons.local_taxi,
          size: 64,
          scale: 2.0,
          isPickup: true,
        );
        final carPoint = safePoint(pos.longitude, pos.latitude);
        if (carPoint != null) {
          _driverCarAnnot = await mgr.create(mapbox.PointAnnotationOptions(
            geometry: carPoint,
            image: carBytes,
            iconSize: 0.7,
            iconAnchor: mapbox.IconAnchor.CENTER,
            iconRotate: bearing,
          ));
        }
      } catch (_) {
        // Silently fail — marker will retry next frame
      }
    } else {
      // Update existing marker position and rotation
      try {
        _driverCarAnnot!.geometry = mapbox.Point(coordinates: mapbox.Position(pos.longitude, pos.latitude));
        _driverCarAnnot!.iconRotate = bearing;
        await mgr.update(_driverCarAnnot!);
      } catch (_) {
        // Marker may have been invalidated — reset and retry
        _driverCarAnnot = null;
      }
    }
  }

  /// Removes the driver car marker from the map.
  void _clearDriverCarMarker() {
    if (_driverCarAnnot != null && _pointAnnotMgr != null) {
      try {
        _pointAnnotMgr!.delete(_driverCarAnnot!);
      } catch (_) {}
      _driverCarAnnot = null;
    }
  }

  // ignore: unused_element – retained for future use
  void _onConfirmPickupCameraIdle() {
    final target = _cameraTarget;
    if (target == null) return;

    _cameraIdleDebounce?.cancel();
    _cameraIdleDebounce = Timer(const Duration(milliseconds: 150), () async {
      if (!mounted || _stage != RideStage.confirmPickup || _isRecentering) {
        return;
      }

      final last = _lastReverseGeocodedTarget;
      if (last != null) {
        final movedMeters = Geolocator.distanceBetween(
          last.latitude,
          last.longitude,
          target.latitude,
          target.longitude,
        );
        if (movedMeters < 15) return;
      }

      _setPickupAnnotation(target);

      final requestTicket = ++_reverseGeocodeTicket;
      try {
        final address = await _places.reverseGeocode(
          lat: target.latitude,
          lng: target.longitude,
        );
        if (!mounted ||
            requestTicket != _reverseGeocodeTicket ||
            _stage != RideStage.confirmPickup) {
          return;
        }
        final resolved = (address == null || address.isEmpty)
            ? _coordinatesLabel(target)
            : address;
        _lastReverseGeocodedTarget = target;
        _setState(() {
          _pickupAddress = resolved;
          _pickupCtrl.text = resolved;
          _setPickupAnnotation(target);
          _currentPosition = target;
        });
        // Silently recalculate route without moving camera
        _silentRouteRecalculate();
      } catch (_) {
        if (!mounted || requestTicket != _reverseGeocodeTicket) return;
        final fallback = _coordinatesLabel(target);
        _setState(() {
          _pickupAddress = fallback;
          _pickupCtrl.text = fallback;
          _setPickupAnnotation(target);
          _currentPosition = target;
        });
        // Silently recalculate route without moving camera
        _silentRouteRecalculate();
      }
    });
  }

  /// Called when user drags the pickup marker to a new position in confirmPickup stage.
  void _onPickupMarkerDragEnd(LatLng newPosition) {
    _currentPosition = newPosition;
    _setPickupAnnotation(newPosition);

    final requestTicket = ++_reverseGeocodeTicket;
    _places
        .reverseGeocode(lat: newPosition.latitude, lng: newPosition.longitude)
        .then((address) {
          if (!mounted ||
              requestTicket != _reverseGeocodeTicket ||
              _stage != RideStage.confirmPickup) {
            return;
          }
          final resolved = (address == null || address.isEmpty)
              ? _coordinatesLabel(newPosition)
              : address;
          _lastReverseGeocodedTarget = newPosition;
          _setState(() {
            _pickupAddress = resolved;
            _pickupCtrl.text = resolved;
            _currentPosition = newPosition;
            _setPickupAnnotation(newPosition);
          });
          _silentRouteRecalculate();
        })
        .catchError((_) {
          if (!mounted || requestTicket != _reverseGeocodeTicket) return;
          final fallback = _coordinatesLabel(newPosition);
          _setState(() {
            _pickupAddress = fallback;
            _pickupCtrl.text = fallback;
            _currentPosition = newPosition;
            _setPickupAnnotation(newPosition);
          });
          _silentRouteRecalculate();
        });
  }
}
