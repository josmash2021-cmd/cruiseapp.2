part of 'driver_online_screen.dart';

/// Room above the week's bars for the amount that rides on each tip.
///
/// Top-level, not a static on the extension below: a class constant reached
/// from inside a part file has failed the iOS build before, with the getter
/// reported as undefined in a const expression.
const double _kBarTipH = 13.0;

/// The height of one stop block on the offer card — its meta line, the gap
/// and the address. Fixed so the marker beside it can be centred exactly.
const double _kOfferStopH = 34.0;

// ══════════════════════════════════════════════════════════════
//  WIDGETS — UI builders, panels, overlays, cards, sheets
// ══════════════════════════════════════════════════════════════

extension _DriverOnlineWidgets on _DriverOnlineScreenState {
  Widget _mapW(bool isDark) {
    // Show a rich skeleton loader when position isn't ready yet.
    // Never show a blank dark blue screen — always have visible feedback.
    if (_pos == null) {
      return Container(
        color: const Color(0xFF07080D),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(
                color: Color(0xFFE8C547),
                strokeWidth: 2,
              ),
              SizedBox(height: 16),
              Text(
                'Loading map...',
                style: TextStyle(
                  color: Color(0xFFE8C547),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Getting your location',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      );
    }
    // MapWidget mounts immediately (no deferred delay). The native
    // PlatformView starts rendering tiles right away. Annotation managers
    // are created in a background microtask inside onMapCreated.
    if (!_mapMounted) {
      return Container(
        color: const Color(0xFF07080D),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(
                color: Color(0xFFE8C547),
                strokeWidth: 2,
              ),
              SizedBox(height: 16),
              Text(
                'Finding trips...',
                style: TextStyle(
                  color: Color(0xFFE8C547),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      );
    }
    // Read once, and hand it down. _mapSurface used to reach back for `_pos!`
    // itself — a bang inside a build method, on a field a dozen callbacks
    // write. The guard above and that dereference were forty lines apart and
    // nothing tied them together.
    final here = _pos!;
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The projection turns a coordinate into a pixel of THIS box, so
          // it has to be measured rather than assumed.
          _onlineMapSize = Size(constraints.maxWidth, constraints.maxHeight);
          final offset = _dotScreenOffset;
          return Stack(
            children: [
              Positioned.fill(child: _mapSurface(isDark, here)),
              // The marker, painted by Flutter: centred while the camera
              // follows, at its own projected pixel once the driver has
              // panned or zoomed away. The Mapbox annotation takes back over
              // only where neither applies — see _dotOverlayOwnsMarker.
              Positioned.fill(
                  child: ListenableBuilder(
                listenable: _markerFrame,
                builder: (context, _) {
                  if (!_dotOverlayOwnsMarker) return const SizedBox.shrink();
                  final o = _dotScreenOffset;
                  final dot = GoldLocationDotOverlay(bearing: _heading);
                  const half = GoldLocationDot.driverOverlaySize / 2;
                  if (o == null) return Center(child: dot);
                  return Stack(children: [
                    Positioned(left: o.dx - half, top: o.dy - half, child: dot),
                  ]);
                },
              )),
            ],
          );
        },
      ),
    );
  }

  Widget _mapSurface(bool isDark, LatLng pos) {
    // The browser draws its own map.
    //
    // mapbox_maps_flutter has no web implementation — MapWidget throws in its
    // first layout. But web/index.html already loads Mapbox GL JS, and
    // lib/map/web_map_view.dart wraps it, so the browser gets a real,
    // interactive map with the same style rather than a grey rectangle.
    if (kIsWeb) {
      return WebMapView(
        initialLng: pos.longitude,
        initialLat: pos.latitude,
        initialZoom: 15.5,
        styleUri: MapboxConfig.styleDark,
      );
    }
    return RepaintBoundary(
      child: mapbox.MapWidget(
        key: _mapKey,
        textureView: true,
        styleUri: MapboxConfig.styleDark,
        cameraOptions: mapbox.CameraOptions(
          center: mapbox.Point(
              coordinates: mapbox.Position(pos.longitude, pos.latitude)),
          zoom:
              16.0, // match home screen zoom — glides to 15.5 via _onSmoothTick
          bearing: 0,
          pitch: 0,
        ),
        onMapCreated: (ctrl) {
          _map = ctrl;
          _lastStyleDark = isDark;
          // Increment generation so any stale annotation refs from the old
          // PlatformView are recognized as dead and recreated fresh.
          _mapGeneration++;
          // CRITICAL: reset all annotation references before creating new managers.
          // On Android the PlatformView (SurfaceView) is destroyed when the app
          // goes to background and recreated on resume. This triggers onMapCreated
          // again with a fresh native map. If we keep stale annotation references
          // pointing to the old map's managers, _updateDriverAnnotation() will
          // try to update/delete non-existent native objects, silently fail,
          // then create duplicates on the new map.
          _polylineAnnotMgr = null;
          _pointAnnotMgr = null;
          _pinAnnotMgr = null;
          _carAnnot = null;
          _carAnnotGen = 0;
          _goldDotAnnot = null;
          _goldDotAnnotGen = 0;
          _pickupAnnot = null;
          _dropoffAnnot = null;
          _prevDriverAnnot = null;
          _prevPickupAnnot = null;
          _prevDropoffAnnot = null;
          _routeAnnot = null;
          _previewPickupAnnot = null;
          _previewDropoffAnnot = null;
          _dotPopDone = false;
          _dotPopScale = 0.0;

          // Move ALL heavy annotation manager creation to a background
          // microtask so the map tiles render FIRST. The driver sees the
          // map immediately; annotations (gold dot, route lines) appear
          // a few frames later. This eliminates the 1-2s blank screen.
          // The generation this map was born in. Everything below is only
          // allowed to touch `ctrl` while it is still the current one.
          final gen = _mapGeneration;

          // This microtask is the app's hardest crash.
          //
          // It captures `ctrl` and then awaits — five times. Between any two
          // of those awaits the native map can be gone: the driver backgrounds
          // the app and Android destroys the SurfaceView, a trip screen takes
          // the surface through the coordinator, the driver pops the screen.
          // `_releaseMapSurface` nulls `_map` and bumps `_mapGeneration`
          // exactly for this, and this method was the one place that never
          // read it. The next `await ctrl.annotations…` then calls into a
          // native object that has been freed — and that does not throw a
          // Dart exception you can catch and shrug at, it takes the process
          // down. The app closes with no error, which is exactly what a
          // driver reports as "it just shuts".
          //
          // So: check the generation after every await, and wrap the lot. A
          // stale pass returns quietly; onMapCreated will run again against
          // the new map and rebuild all of this from scratch.
          Future.microtask(() async {
            bool stale() => !mounted || _mapGeneration != gen || _map == null;
            try {
              // Pan and zoom, but the driver never turns the map by hand.
              //
              // The camera does still rotate on its own while navigating —
              // that is the map facing the direction of travel, the same as
              // every turn-by-turn app. What is gone is the two-finger twist,
              // which could leave the map at an angle nothing would ever
              // correct, with the arrow pointing somewhere that no longer
              // matched the streets under it.
              await ctrl.gestures.updateSettings(mapbox.GesturesSettings(
                scrollEnabled: true,
                pinchToZoomEnabled: true,
                doubleTapToZoomInEnabled: true,
                doubleTouchToZoomOutEnabled: true,
                quickZoomEnabled: true,
                rotateEnabled: false,
                pitchEnabled: false,
                simultaneousRotateAndPinchToZoomEnabled: false,
              ));
              if (stale()) return;

              // Polyline manager with no 'below' constraint — avoids silent failure
              // when the layer name doesn't exist in the style.
              final poly =
                  await ctrl.annotations.createPolylineAnnotationManager(
                below: "road-label",
              );
              if (stale()) return;
              _polylineAnnotMgr = poly;

              final point =
                  await ctrl.annotations.createPointAnnotationManager();
              if (stale()) return;
              _pointAnnotMgr = point;
              try {
                await ctrl.style.setStyleLayerProperty(
                    point.id, 'icon-pitch-alignment', 'viewport');
              } catch (_) {}
              try {
                await ctrl.style.setStyleLayerProperty(
                    point.id, 'icon-allow-overlap', true);
              } catch (_) {}
              try {
                await ctrl.style.setStyleLayerProperty(
                    point.id, 'icon-ignore-placement', true);
              } catch (_) {}
              if (stale()) return;

              // Separate pin manager for teardrop pins — anchored at tip (bottom), upright (viewport)
              final pin = await ctrl.annotations.createPointAnnotationManager();
              if (stale()) return;
              _pinAnnotMgr = pin;
              try {
                await ctrl.style.setStyleLayerProperty(
                    pin.id, 'icon-pitch-alignment', 'viewport');
              } catch (_) {}
              try {
                await ctrl.style.setStyleLayerProperty(
                    pin.id, 'icon-rotation-alignment', 'viewport');
              } catch (_) {}
              try {
                await ctrl.style
                    .setStyleLayerProperty(pin.id, 'icon-allow-overlap', true);
              } catch (_) {}
              try {
                await ctrl.style.setStyleLayerProperty(
                    pin.id, 'icon-ignore-placement', true);
              } catch (_) {}
              try {
                await ctrl.style
                    .setStyleLayerProperty(pin.id, 'icon-anchor', 'bottom');
              } catch (_) {}
              if (stale()) return;

              // Use already-known position from home screen — no blocking GPS call needed
              final here = _pos;
              if (here != null) {
                _animateToPosition(here,
                    zoom: 16.0, bearing: _heading, tilt: 0);
              }
              _updateDriverAnnotation();
              // Re-draw route if map initialised after _drawRoute already ran
              if (_routePts.length > 1) {
                _setRouteAnnotation(_routePts, _navyRoute);
                final dest = (_phase == _Phase.enRouteToPickup ||
                        _phase == _Phase.routeSummary)
                    ? _pickupLL
                    : _dropoffLL;
                if (here != null) _fitBounds(here, dest);
              }
            } catch (e) {
              // Unhandled before. Anything thrown here aborted the rest of
              // the method, so the driver dot was never drawn either — the
              // "the arrow is missing" report and this one share a cause.
              debugPrint('[DriverOnline] annotation setup failed: $e');
            }
          });
        },
        onStyleLoadedListener: (_) async {
          if (_map != null) {
            await MapTheme.applyNavyGold(_map!);
            // Ensure top-down view on entry (no tilt unless actively navigating)
            if (_phase == _Phase.searching || _phase == _Phase.rideRequest) {
              // The only camera write on this screen still outside the
              // guarded helper, and it needed its own catch: a style reload
              // can be the last thing a surface does before it is torn down.
              try {
                await _map!.flyTo(
                  mapbox.CameraOptions(pitch: 0, bearing: 0),
                  mapbox.MapAnimationOptions(duration: 0),
                );
              } catch (e) {
                debugPrint('[DriverOnline] flatten on style load failed: $e');
              }
            }
            // Re-apply pin layer properties after style reload —
            // applyNavyGold resets them so they must be re-set here.
            if (_pinAnnotMgr != null) {
              try {
                await _map!.style.setStyleLayerProperty(
                    _pinAnnotMgr!.id, 'icon-rotation-alignment', 'viewport');
              } catch (_) {}
              try {
                await _map!.style.setStyleLayerProperty(
                    _pinAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
              } catch (_) {}
              try {
                await _map!.style.setStyleLayerProperty(
                    _pinAnnotMgr!.id, 'icon-anchor', 'bottom');
              } catch (_) {}
              try {
                await _map!.style.setStyleLayerProperty(
                    _pinAnnotMgr!.id, 'icon-allow-overlap', true);
              } catch (_) {}
            }
            if (_pointAnnotMgr != null) {
              try {
                await _map!.style.setStyleLayerProperty(
                    _pointAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
              } catch (_) {}
              try {
                await _map!.style.setStyleLayerProperty(
                    _pointAnnotMgr!.id, 'icon-allow-overlap', true);
              } catch (_) {}
            }
          }
        },
        onScrollListener: (_) {
          _onCameraMoveStarted();
        },
        onCameraChangeListener: (data) {
          _onlineCamState = data.cameraState;
          // See the same listener on the home screen: the overlay's pixel
          // comes from this camera, and the motion ticker parks when the
          // driver stops, so without this the arrow would stick to a stale
          // pixel while a stationary driver drags the map.
          _markerFrame.value++;
        },
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  EARNINGS PILL (top center — Uber style)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _earningsPill(bool isDark) {
    final pillBg = isDark ? Colors.black : Colors.white.withValues(alpha: 0.9);
    final pillBorder = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);
    final pillText = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final pillSub = isDark ? Colors.white38 : Colors.black38;
    final dotActive = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final dotInactive = isDark
        ? Colors.white.withValues(alpha: 0.2)
        : Colors.black.withValues(alpha: 0.15);

    // The same three spans as the home screen, in the same order: today,
    // this week, this month. It used to be week / today / last trip, so
    // going online reshuffled the pages under the driver's thumb and the
    // figure they were looking at moved. One control, one order.
    //
    // Last trip went with the reshuffle. It answers a different question
    // ("what did that one pay?") and the trip's own summary already
    // answers it.
    final amounts = [_earnings, _weeklyEarnings, _monthlyEarnings];
    final prevAmounts = [
      _prevEarnings,
      _prevWeeklyEarnings,
      _prevMonthlyEarnings,
    ];
    final labels = [
      S.of(context).today.toUpperCase(),
      S.of(context).weekLabel.toUpperCase(),
      S.of(context).monthLabel.toUpperCase(),
    ];
    final pageCount = amounts.length;

    // Clamp _earningsPage so it never points past the last valid page
    // (e.g. when a driver goes from 3 pages to 2 after app restart).
    final safePage = _earningsPage.clamp(0, pageCount - 1);

    Widget pillPage(double amount, double prevAmount, String label) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: isDark
                ? neuBox(radius: 20, borderColor: pillBorder)
                : BoxDecoration(
                    color: pillBg,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: pillBorder),
                  ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TweenAnimationBuilder<double>(
                  key: ValueKey<double>(amount),
                  duration: const Duration(milliseconds: 900),
                  curve: Curves.easeOutCubic,
                  tween: Tween<double>(begin: prevAmount, end: amount),
                  // The figure, or a bare $ standing in for it.
                  //
                  // This chip sits at the top of the map and is the most
                  // legible thing on the screen from a back seat, which is
                  // why the switch in Earnings exists and why this is what
                  // it covers.
                  builder: (_, val, __) => Text(
                    EarningsPrivacy.format(val),
                    style: TextStyle(
                      color: pillText,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: pillSub,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(width: 6),
                    for (int i = 0; i < pageCount; i++) ...[
                      Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i == safePage ? dotActive : dotInactive,
                        ),
                      ),
                      if (i < pageCount - 1) const SizedBox(width: 3),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity == null) return;
        if (details.primaryVelocity! < -200 && safePage < pageCount - 1) {
          _setState(() => _earningsPage = safePage + 1);
        } else if (details.primaryVelocity! > 200 && safePage > 0) {
          _setState(() => _earningsPage = safePage - 1);
        }
      },
      child: SizedBox(
        width: 160,
        height: 52,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          reverseDuration: const Duration(milliseconds: 300),
          switchInCurve: Curves.easeInOut,
          switchOutCurve: Curves.easeInOut,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: child,
          ),
          child: Center(
            key: ValueKey<int>(safePage),
            child: pillPage(
              amounts[safePage],
              prevAmounts[safePage],
              labels[safePage],
            ),
          ),
        ),
      ),
    );
  }

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
//  BOTTOM AREA (per phase)
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _bottomArea(
    bool isDark,
    Color bg,
    Color surface,
    Color textPrimary,
    Color textMuted,
    Color borderC,
    Color shadowC,
  ) {
    switch (_phase) {
      case _Phase.searching:
        return _searchingBar(isDark, surface, textMuted, borderC);
      case _Phase.rideRequest:
        return const SizedBox.shrink(); // handled by stacked cards overlay
      // The trip is run by DriverTripAcceptScreen, which this screen pushes
      // on accept. These four phases belonged to an earlier design where the
      // whole ride happened here instead — panels, turn-by-turn, arrival and
      // start-trip buttons, a tilted navigation camera. Nothing has been able
      // to enter that flow since the separate screen was introduced: its two
      // doors, _showPickupSummary and _toPickup, had no callers at all, and
      // every other state in it was only reachable from another state inside
      // it. A closed loop with no entrance.
      //
      // The panels are gone. The phase constants stay because they are still
      // read by camera, GPS and annotation code as harmless guards, and
      // unpicking those is a separate job with its own risk.
      case _Phase.enRouteToPickup:
      case _Phase.arrivedAtPickup:
      case _Phase.routeSummary:
      case _Phase.inTrip:
      case _Phase.completed:
        return const SizedBox.shrink();
    }
  }

  // â”€â”€ SEARCHING: Uber-style "Finding trips" bar â”€â”€
  Widget _searchingBar(
    bool isDark,
    Color surface,
    Color textMuted,
    Color borderC,
  ) {
    return _enterBarWrap(GestureDetector(
      onVerticalDragUpdate: (d) {
        // Detect swipe up (negative dy) to open the panel
        if (d.delta.dy < -3) _showOnlinePanel();
      },
      behavior: HitTestBehavior.opaque,
      child: ListenableBuilder(
        listenable: _searchPulseVal,
        builder: (_, __) => CustomPaint(
          foregroundPainter: _SearchingBorderPainter(
            progress: _searchPulseVal.value,
          ),
          child: Container(
            decoration: BoxDecoration(
              // Neumorphic dark base (no particles per 2026-04-27
              // spec — particles only on Searching + Waiting screens).
              // The animated gold border above is the searching pulse.
              color: neuBase,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(18)),
              border: Border(top: BorderSide(color: borderC)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 2), // Spacer for border glow
                  // Drag handle
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 4),
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: textMuted.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // Status bar — swipe on parent opens panel
                  SizedBox(
                    height: 50,
                    child: Row(
                      children: [
                        // Closed, the bar carries the status and nothing else.
                        //
                        // The avatar and the list button sat either side of it
                        // and neither did anything the driver needed while
                        // waiting — the avatar is not a control at all, and the
                        // list duplicates what opening the panel gives. Safety
                        // and Reserved appear in their place, but only once the
                        // panel is open and there is room to label them.
                        const SizedBox(width: 16),
                        const Spacer(),
                        // Connection status dot: green = SSE real-time, amber = polling fallback
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: _sseActive
                                ? const Color(0xFF4CAF50)
                                : const Color(0xFFFFA000),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: (_sseActive
                                        ? const Color(0xFF4CAF50)
                                        : const Color(0xFFFFA000))
                                    .withValues(alpha: 0.4),
                                blurRadius: 6,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Centred: a Spacer either side, so the dot and the label
                        // sit together in the middle of the bar whatever the
                        // label's width does as it swaps between the two lines.
                        _searchingLabel(textMuted),
                        const Spacer(),
                        const SizedBox(width: 16),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ),
        ),
      ),
    ));
  }

  /// Entrance wrapper: slides a widget up from below with a soft spring
  /// (easeOutBack) + fade when the screen first appears.
  Widget _enterBarWrap(Widget child) {
    return AnimatedBuilder(
      animation: _enterBar,
      builder: (_, c) => Opacity(
        opacity: _enterBar.value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, 40 * (1 - _enterBar.value)),
          child: c,
        ),
      ),
      child: child,
    );
  }

  /// Entrance wrapper for top chrome (back button, earnings pill,
  /// scheduled-rides FAB): fade + slide down from ~20px above.
  Widget _enterTopWrap(Widget child) {
    return AnimatedBuilder(
      animation: _enterTop,
      builder: (_, c) => Opacity(
        opacity: _enterTop.value,
        child: Transform.translate(
          offset: Offset(0, -20 * (1 - _enterTop.value)),
          child: c,
        ),
      ),
      child: child,
    );
  }

  // â”€â”€ STACKED RIDE OFFER CARDS (Spark-style — persistent, no timeout) â”€â”€
  Widget _rideOfferCards(
    bool isDark,
    Color card,
    Color textPrimary,
    Color textMuted,
    Color borderC,
    Color shadowC,
  ) {
    // Clears the home indicator. Was computed here and never used,
    // while the panel was pulled 30 px off screen instead.
    final bot = MediaQuery.of(context).padding.bottom;
    // ── Always use dark styling for offer cards ──
    const cCardBg = neuSurface;
    final cCardBorder = _gold.withValues(alpha: 0.12);
    final cRejectBg = Colors.red.withValues(alpha: 0.08);
    const cRejectText = Color(0xFFFF6B6B);
    const cTextPrimary = Colors.white;
    final cTextMuted = Colors.white.withValues(alpha: 0.5);
    final cBorderC = Colors.white.withValues(alpha: 0.06);
    final acceptBg = _gold;

    final safeIdx =
        _currentOfferIndex.clamp(0, (_pendingOffers.length - 1).clamp(0, 999));
    final currentOid = _pendingOffers.isNotEmpty
        ? (_pendingOffers[safeIdx]['offer_id'] ??
                _pendingOffers[safeIdx]['id'] ??
                '')
            .toString()
        : '';
    final isCardExpanded = _expandedOfferIds.contains(currentOid);

    return Padding(
      padding: EdgeInsets.only(bottom: bot > 0 ? bot * 0.5 : 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // â”€â”€ Tappable header: handle + title + chevron â”€â”€
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  S.of(context).ridesAvailable(_pendingOffers.length),
                  style: const TextStyle(
                    color: _gold,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
          // ── Horizontal swipeable offer cards (responsive) ──
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            height: _offerCardHeight(context),
            child: PageView.builder(
              controller: _offerPageCtrl,
              onPageChanged: (index) {
                _setState(() => _currentOfferIndex = index);
                HapticService.selectionClick();
                // Swiping between offers browses them; it does not draw.
                // Only an explicit tap on a card builds its route and pins.
              },
              itemCount: _pendingOffers.length,
              itemBuilder: (ctx, i) {
                final offer = _pendingOffers[i];
                final oid = (offer['offer_id'] ?? offer['id'] ?? '').toString();
                final isAnimating = _animatingOfferId == oid;
                final isRejecting = _rejectingOfferId == oid;
                Widget card = _offerCard(
                  offer,
                  true,
                  cCardBg,
                  cCardBorder,
                  cTextPrimary,
                  cTextMuted,
                  cRejectBg,
                  cRejectText,
                  acceptBg,
                  cBorderC,
                  // Only the page the driver is on runs its countdown. The
                  // PageView builds its neighbour too, and a clock ticking
                  // on an offer nobody has seen expires it for them.
                  isVisible: i == _currentOfferIndex,
                );
                // Pulse scale on tap-down/tap-up
                if (isAnimating && _pulseAnim != null) {
                  card = AnimatedBuilder(
                    animation: _pulseAnim!,
                    builder: (_, child) => Transform.scale(
                      scale: _pulseAnim!.value,
                      child: child,
                    ),
                    child: card,
                  );
                }
                // Reject slide-down animation
                if (isRejecting && _rejectSlideCtrl != null) {
                  card = AnimatedBuilder(
                    animation: _rejectSlideCtrl!,
                    builder: (_, child) => Transform.translate(
                      offset: Offset(0, _rejectSlideCtrl!.value * 400),
                      child: Opacity(
                        opacity:
                            (1.0 - _rejectSlideCtrl!.value).clamp(0.0, 1.0),
                        child: child,
                      ),
                    ),
                    child: card,
                  );
                }
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (_) {
                    _setState(() => _animatingOfferId = oid);
                    _pulseCtrl?.forward();
                  },
                  // A tap does nothing but release the press animation.
                  // The route draws itself when the card arrives; making
                  // the tap draw it again meant a driver reading the
                  // addresses restarted the camera under their own finger.
                  onTap: () => _pulseCtrl?.reverse(),
                  onTapCancel: () {
                    _pulseCtrl?.reverse();
                  },
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    child: card,
                  ),
                );
              },
            ),
          ),
          // ── Page indicator dots ──
          if (_pendingOffers.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_pendingOffers.length, (i) {
                  final active = i == _currentOfferIndex;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: active ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color:
                          active ? _gold : Colors.white.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  );
                }),
              ),
            ),
          // â”€â”€ Scrollable card list (hidden when collapsed) â”€â”€

          // â”€â”€ "Finding trips" bar at the bottom â”€â”€
          ClipRect(
            child: AnimatedSlide(
              offset: _hideFindingBar ? const Offset(0, 1) : Offset.zero,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeInOut,
              child: AnimatedOpacity(
                opacity: _hideFindingBar ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 300),
                child: GestureDetector(
                  onTap: _hideFindingBar ? null : _showGoOfflineSheet,
                  onVerticalDragUpdate: _hideFindingBar
                      ? null
                      : (details) {
                          if (details.delta.dy < -5) {
                            _showGoOfflineSheet();
                          }
                        },
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    decoration: BoxDecoration(
                      color: neuBase,
                      border: Border(
                        top: BorderSide(
                          color: Colors.white.withValues(alpha: 0.06),
                        ),
                      ),
                    ),
                    child: SafeArea(
                      top: false,
                      child: SizedBox(
                        height: 62,
                        child: Row(
                          children: [
                            const SizedBox(width: 16),
                            Icon(
                              Icons.tune_rounded,
                              color: Colors.white.withValues(alpha: 0.5),
                              size: 22,
                            ),
                            const Spacer(),
                            Text(
                              S.of(context).findingTrips,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            Icon(
                              Icons.format_list_bulleted_rounded,
                              color: Colors.white.withValues(alpha: 0.5),
                              size: 22,
                            ),
                            const SizedBox(width: 16),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Shows the Go Offline bottom sheet (accessible from Finding trips bar)
  void _showGoOfflineSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF1A1A1F) : Colors.white;
    final textPrimary = isDark ? Colors.white : Colors.black;
    final textMuted = isDark
        ? Colors.white.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.5);
    final borderC = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);
    final panelItemText = isDark
        ? Colors.white.withValues(alpha: 0.7)
        : Colors.black.withValues(alpha: 0.6);
    final panelItemIcon = isDark
        ? Colors.white.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.4);
    final panelItemChevron = isDark
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.black.withValues(alpha: 0.12);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      enableDrag: true,
      builder: (ctx) {
        final maxH = MediaQuery.of(ctx).size.height * 0.82;
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: Container(
            decoration: BoxDecoration(
              color: surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
              border:
                  Border(top: BorderSide(color: _gold.withValues(alpha: 0.08))),
            ),
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 10),
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: textMuted.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 40,
                      child: Row(
                        children: [
                          const SizedBox(width: 16),
                          Icon(Icons.tune_rounded, color: textMuted, size: 22),
                          const Spacer(),
                          Text(
                            S.of(context).findingTrips,
                            style: TextStyle(
                              color: textMuted,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          Icon(
                            Icons.format_list_bulleted_rounded,
                            color: textMuted,
                            size: 22,
                          ),
                          const SizedBox(width: 16),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Divider(height: 1, color: borderC),
                    const SizedBox(height: 12),
                    const SizedBox(height: 16),
                    Divider(height: 1, color: borderC),
                    const SizedBox(height: 16),
                    Text(
                      S.of(context).recommendedForYou,
                      style: TextStyle(
                        color: textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _panelItem(
                      Icons.bar_chart_rounded,
                      S.of(context).seeEarningsTrends,
                      panelItemIcon,
                      panelItemText,
                      panelItemChevron,
                      () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          slideFromRightRoute(const DriverEarningsScreen()),
                        );
                      },
                    ),
                    const SizedBox(height: 20),
                    // PAUSE and GO OFFLINE buttons row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        // PAUSE button
                        GestureDetector(
                          onTap: () {
                            Navigator.pop(context);
                            _pauseAvailability();
                          },
                          child: Column(
                            children: [
                              Container(
                                width: 62,
                                height: 62,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: const Color(0xFFFFA500)
                                      .withValues(alpha: 0.15),
                                  border: Border.all(
                                    color: const Color(0xFFFFA500)
                                        .withValues(alpha: 0.3),
                                    width: 2,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.pause_circle_filled_rounded,
                                  color: Color(0xFFFFA500),
                                  size: 26,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'PAUSE'.toUpperCase(),
                                style: const TextStyle(
                                  color: Color(0xFFFFA500),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // GO OFFLINE button
                        GestureDetector(
                          onTap: () {
                            Navigator.pop(context);
                            _goOffline();
                          },
                          child: Column(
                            children: [
                              Container(
                                width: 62,
                                height: 62,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: const Color(
                                    0xFFCC3333,
                                  ).withValues(alpha: 0.15),
                                  border: Border.all(
                                    color: const Color(
                                      0xFFCC3333,
                                    ).withValues(alpha: 0.3),
                                    width: 2,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.pan_tool_rounded,
                                  color: Color(0xFFCC3333),
                                  size: 26,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                S.of(context).goOffline.toUpperCase(),
                                style: const TextStyle(
                                  color: Color(0xFFCC3333),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Safely extract a finite double from dynamic backend data.
  /// Rejects null, NaN, and Infinity so downstream calculations never throw.
  double _safeDouble(dynamic value, {double fallback = 0}) {
    if (value == null) return fallback;
    final d = (value as num).toDouble();
    if (d.isNaN || d.isInfinite) return fallback;
    return d;
  }

  /// Decode a Google/OSRM polyline string into a list of [lng,lat] coordinate pairs.
  List<List<double>> _decodePolylineCoords(String encoded) {
    final pts = <List<double>>[];
    int i = 0, lat = 0, lng = 0;
    while (i < encoded.length) {
      int s = 0, r = 0, b;
      do {
        b = encoded.codeUnitAt(i++) - 63;
        r |= (b & 0x1F) << s;
        s += 5;
      } while (b >= 0x20);
      lat += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      s = 0;
      r = 0;
      do {
        b = encoded.codeUnitAt(i++) - 63;
        r |= (b & 0x1F) << s;
        s += 5;
      } while (b >= 0x20);
      lng += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      pts.add([lng / 1E5, lat / 1E5]);
    }
    return pts;
  }

  /// Fetch both legs (driver→pickup + pickup→dropoff) from OSRM and build
  /// a Mapbox Static API URL with the real road polyline overlaid.
  Future<String> _buildOfferMapUrl(
    LatLng driver,
    LatLng pickup,
    LatLng dropoff,
  ) async {
    final token = MapboxConfig.accessToken;
    // Guard against NaN/Infinity coordinates that crash toStringAsFixed
    double safeCoord(double v) => v.isFinite ? v : 0.0;
    final dLng = safeCoord(driver.longitude).toStringAsFixed(6);
    final dLat = safeCoord(driver.latitude).toStringAsFixed(6);
    final pLng = safeCoord(pickup.longitude).toStringAsFixed(6);
    final pLat = safeCoord(pickup.latitude).toStringAsFixed(6);
    final oLng = safeCoord(dropoff.longitude).toStringAsFixed(6);
    final oLat = safeCoord(dropoff.latitude).toStringAsFixed(6);

    // Fetch two legs from OSRM
    List<List<double>> allPts = [];
    try {
      // Leg 1: driver → pickup
      final uri1 = Uri.https(
        'router.project-osrm.org',
        '/route/v1/driving/${driver.longitude},${driver.latitude};${pickup.longitude},${pickup.latitude}',
        {'overview': 'full', 'geometries': 'polyline'},
      );
      final r1 = await http.get(uri1).timeout(const Duration(seconds: 6));
      final d1 = jsonDecode(r1.body);
      if (d1 is Map && d1['code']?.toString().toUpperCase() == 'OK') {
        final geo1 = (d1['routes'] as List?)?.first?['geometry']?.toString();
        if (geo1 != null) allPts.addAll(_decodePolylineCoords(geo1));
      }
    } catch (_) {}

    try {
      // Leg 2: pickup → dropoff
      final uri2 = Uri.https(
        'router.project-osrm.org',
        '/route/v1/driving/${pickup.longitude},${pickup.latitude};${dropoff.longitude},${dropoff.latitude}',
        {'overview': 'full', 'geometries': 'polyline'},
      );
      final r2 = await http.get(uri2).timeout(const Duration(seconds: 6));
      final d2 = jsonDecode(r2.body);
      if (d2 is Map && d2['code']?.toString().toUpperCase() == 'OK') {
        final geo2 = (d2['routes'] as List?)?.first?['geometry']?.toString();
        if (geo2 != null) allPts.addAll(_decodePolylineCoords(geo2));
      }
    } catch (_) {}

    // Pins
    final driverPin = 'pin-s-car+1a73e8($dLng,$dLat)';
    final pickupPin = 'pin-s+00c853($pLng,$pLat)';
    final dropoffPin = 'pin-s+333333($oLng,$oLat)';

    String pathOverlay;
    if (allPts.length >= 2) {
      // Subsample to ≤100 points so URL stays within Mapbox's 8192-char limit
      final step = allPts.length > 100 ? (allPts.length / 100).ceil() : 1;
      final sampled = <List<double>>[];
      for (int k = 0; k < allPts.length; k += step) {
        sampled.add(allPts[k]);
      }
      if (sampled.last != allPts.last) sampled.add(allPts.last);
      final coords = sampled
          .map((p) => '${p[0].toStringAsFixed(5)},${p[1].toStringAsFixed(5)}')
          .join(';');
      pathOverlay = 'path-4+3b82f6-1($coords)';
    } else {
      // Fallback: straight line
      pathOverlay = 'path-3+3b82f6-0.8($dLng,$dLat;$pLng,$pLat;$oLng,$oLat)';
    }

    return 'https://api.mapbox.com/styles/v1/mapbox/dark-v11/static/'
        '$driverPin,$pickupPin,$dropoffPin,$pathOverlay'
        '/auto/700x320@2x?padding=70,50,50,50&access_token=$token';
  }

  Widget _offerCard(
    Map<String, dynamic> offer,
    bool isDark,
    Color cardBg,
    Color cardBorder,
    Color textPrimary,
    Color textMuted,
    Color rejectBg,
    Color rejectText,
    Color acceptBg,
    Color borderC, {
    required bool isVisible,
  }) {
    const luxGold = Color(0xFFD4AF37);

    // Parse offer data with NaN/Infinity guards — backend can send malformed
    // coordinates that crash distance calculations (ceil/toStringAsFixed on NaN).
    // Rating display rules (backend-driven via rider_rides_count):
    //   rider_is_new == true                          -> "New rider"
    //   ratingsCount > 0 && rating > 0                -> show star rating
    //   else                                          -> show nothing
    final rating = _safeDouble(offer['rider_rating']);
    final ratingsCount = _safeDouble(offer['rider_ratings_count']).toInt();
    final riderIsNew = offer['rider_is_new'] == true;
    final hasRating = !riderIsNew && ratingsCount > 0 && rating > 0;
    final fare = _safeDouble(offer['fare']);
    final rawPickupAddr =
        (offer['pickup_address'] as String?) ?? S.of(context).pickupFallback;
    final dropoffAddr =
        (offer['dropoff_address'] as String?) ?? S.of(context).dropoffFallback;
    final pickupLat = _safeDouble(offer['pickup_lat']);
    final pickupLng = _safeDouble(offer['pickup_lng']);
    final dropoffLat = _safeDouble(offer['dropoff_lat']);
    final dropoffLng = _safeDouble(offer['dropoff_lng']);
    final vehicleType =
        _mapRideType((offer['vehicle_type'] ?? 'Comfort') as String);
    final pickupLL = LatLng(pickupLat, pickupLng);
    final dropoffLL = LatLng(dropoffLat, dropoffLng);
    final pickupAddr = _isGenericAddress(rawPickupAddr)
        ? (_resolvedAddressCache['${pickupLat}_$pickupLng'] ?? rawPickupAddr)
        : rawPickupAddr;

    // Cache per offer so we don't re-fetch on every rebuild
    final offerId =
        (offer['offer_id'] ?? offer['id'] ?? '${pickupLat}_$pickupLng')
            .toString();

    // Use real Directions API metrics from route cache when available,
    // fall back to haversine estimate.
    final cached = _routeCache[offerId];
    final double distToPickupKm;
    final int etaToPickup;
    final double distToPickupMi;
    final double tripDistKm;
    final int tripEta;
    final double tripDistMi;
    if (cached?.driverToPickupKm != null && cached?.pickupToDropoffKm != null) {
      distToPickupKm = cached!.driverToPickupKm!;
      etaToPickup = (cached.driverToPickupMin ?? 1).ceil().clamp(1, 99);
      distToPickupMi = distToPickupKm * 0.621371;
      tripDistKm = cached.pickupToDropoffKm!;
      tripEta = (cached.pickupToDropoffMin ?? 1).ceil().clamp(1, 99);
      tripDistMi = tripDistKm * 0.621371;
    } else {
      if (_pos != null) {
        var dtp = _hav(_pos!, pickupLL);
        // Guard against NaN from _hav with invalid coordinates
        if (!dtp.isFinite) dtp = 0;
        distToPickupKm = dtp;
        etaToPickup = (dtp * 1000 / 17.88 / 60).ceil().clamp(1, 99);
        distToPickupMi = dtp * 0.621371;
      } else {
        distToPickupKm = 0;
        etaToPickup = 1;
        distToPickupMi = 0;
      }
      var td = _hav(pickupLL, dropoffLL);
      if (!td.isFinite) td = 0;
      tripDistKm = td;
      tripEta = (td * 1000 / 17.88 / 60).ceil().clamp(1, 99);
      tripDistMi = td * 0.621371;
    }

    if (_pos != null &&
        pickupLat != 0 &&
        pickupLng != 0 &&
        dropoffLat != 0 &&
        dropoffLng != 0) {
      _offerMapUrlCache.putIfAbsent(
        offerId,
        () => _buildOfferMapUrl(_pos!, pickupLL, dropoffLL),
      );
    }

    final isExpanded = _expandedOfferIds.contains(offerId);

    return Container(
      clipBehavior: Clip.antiAlias,
      // The card is the app's raised surface, not a black panel with a gold
      // outline. The gold now lives on the fare, the metrics and the
      // countdown, where it means something.
      decoration: neuBox(radius: 20),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, anim) =>
                  FadeTransition(opacity: anim, child: child),
              child: _buildNormalCardContent(
                offer: offer,
                offerId: offerId,
                fare: fare,
                rating: rating,
                riderIsNew: riderIsNew,
                hasRating: hasRating,
                vehicleType: vehicleType,
                etaToPickup: etaToPickup,
                distToPickupMi: distToPickupMi,
                pickupAddr: pickupAddr,
                tripEta: tripEta,
                tripDistMi: tripDistMi,
                dropoffAddr: dropoffAddr,
                isExpanded: isExpanded,
                isVisible: isVisible,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Normal card content (default offer view) ──
  Widget _buildNormalCardContent({
    required Map<String, dynamic> offer,
    required String offerId,
    required double fare,
    required double rating,
    required bool riderIsNew,
    required bool hasRating,
    required String vehicleType,
    required int etaToPickup,
    required double distToPickupMi,
    required String pickupAddr,
    required int tripEta,
    required double tripDistMi,
    required String dropoffAddr,
    required bool isExpanded,
    required bool isVisible,
  }) {
    const goldAccent = Color(0xFFE8C547);
    const rejectRed = Color(0xFFE53935);

    // ── Scheduled ride detection ──
    // A web booking for "right now" still has `scheduled_at` set (to the
    // current moment), but from the driver's perspective it is an on-demand
    // trip and must NOT show the "VIAJE RESERVADO" badge. Only treat the
    // offer as scheduled when the pickup time is at least 3 minutes in the
    // future — truly-future bookings keep the reservation badge and the
    // purple accent; immediate bookings fall through to the normal layout.
    final scheduledAtRaw = offer['scheduled_at'];
    final DateTime? scheduledAt = scheduledAtRaw != null
        ? DateTime.tryParse(scheduledAtRaw.toString())?.toLocal()
        : null;
    final bool isScheduled = scheduledAt != null &&
        scheduledAt.difference(DateTime.now()).inMinutes >= 3;
    final bool isAirportTrip = offer['is_airport'] == true;
    // Cash ride detection — backend sends `payment_method: 'cash'` when the
    // rider chose to pay in cash at the end of the trip. Accept a few
    // possible keys for forward compat.
    final String paymentMethod = (offer['payment_method'] ??
            offer['paymentMethod'] ??
            offer['payment_type'] ??
            '')
        .toString()
        .toLowerCase();
    final bool isCashRide = paymentMethod == 'cash' || offer['is_cash'] == true;

    // ── Badge policy (2026-04-11, stack-of-badges) ──────────────────
    // Immediate trips paid by card → NO badges (the card is clean).
    // Immediate trips paid by cash → only the standalone CASH RIDE badge.
    // Scheduled trips → always include RESERVED, then ADD the modifiers
    //   (AIRPORT and/or CASH) as separate stacked badges in a Wrap.
    //
    // The vehicle-type shimmer badge (Comfort/Premium/VIP) is removed
    // entirely — vehicle type is redundant with the fare/route info.
    //
    // Localization is via S.of(context) so the labels render in
    // Spanish on Spanish phones and English on English phones.
    final s = S.of(context);
    final List<_OfferBadgeData> badges = [];
    if (isScheduled) {
      // Future-scheduled trip — RESERVED is the anchor badge, plus
      // optional AIRPORT and CASH modifiers stacked next to it.
      badges.add(_OfferBadgeData(
        label: s.badgeReserved,
        icon: Icons.schedule_rounded,
        color: const Color(0xFF8B5CF6), // purple
      ));
      if (isAirportTrip) {
        badges.add(_OfferBadgeData(
          label: s.badgeAirport,
          icon: Icons.flight_takeoff_rounded,
          color: const Color(0xFF3B82F6), // blue
        ));
      }
      if (isCashRide) {
        badges.add(_OfferBadgeData(
          label: s.badgeCash,
          icon: Icons.payments_rounded,
          color: const Color(0xFF10B981), // green
        ));
      }
    } else if (isCashRide) {
      // Immediate cash trip — single standalone CASH RIDE badge.
      // (Immediate airport trips are NOT badged per product policy:
      // there is no "reservation" to advertise; the airport pickup
      // address itself communicates the trip type.)
      badges.add(_OfferBadgeData(
        label: s.badgeCashRide,
        icon: Icons.payments_rounded,
        color: const Color(0xFF10B981), // green
      ));
    }
    // Immediate, card-paid trips fall through with no badges at all.

    // What the trip pays per hour of the driver's time — drive-to-pickup
    // included, because that time is spent whether or not it is paid.
    // Shown next to the fare so a short expensive trip and a long cheap one
    // stop looking the same.
    final totalMin = (etaToPickup + tripEta).clamp(1, 999);
    final hourly = fare / (totalMin / 60.0);

    return Column(
      key: const ValueKey('compact'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Badges (scheduled / airport / cash) ─────────────────────
        if (badges.isNotEmpty) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final b in badges) _buildOfferBadge(b),
            ],
          ),
          const SizedBox(height: 4),
          if (isScheduled) ...[
            Row(
              children: [
                const Icon(Icons.access_time_rounded,
                    size: 14, color: Color(0xFFE8C547)),
                const SizedBox(width: 4),
                Text(
                  _formatScheduledTime(scheduledAt),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFE8C547),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
        ],

        // ── Fare, hourly rate, and the clock, on one line ───────────
        // Top-aligned: the clock belongs beside the fare, not floating in
        // the middle of the three lines under it.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        '\$${fare.toStringAsFixed(2)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        S.of(context).plusTips,
                        style: const TextStyle(
                          color: goldAccent,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    S.of(context).offerHourlyRate(hourly.toStringAsFixed(2)),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _offerMetric(
                        Icons.access_time_rounded,
                        S.of(context).offerDuration(totalMin),
                      ),
                      const SizedBox(width: 8),
                      _offerMetric(
                        Icons.straighten_rounded,
                        '${(distToPickupMi + tripDistMi).toStringAsFixed(1)} mi',
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // The clock, level with the fare. Keyed on the offer so a new
            // one starts fresh and a rebuild of this one does not.
            OfferCountdownRing(
              key: ValueKey('countdown_$offerId'),
              active: isVisible,
              onExpired: () {
                if (!mounted) return;
                _rejectOffer(offer);
              },
              // cruise_logo.png, not logoapp.png: the latter is the same
              // mark baked onto a black square, which inside the ring
              // showed up as a black box around the car.
              child: Image.asset(
                'assets/images/cruise_logo.png',
                fit: BoxFit.contain,
              ),
            ),
          ],
        ),

        const SizedBox(height: 18),

        // ── Pickup, then dropoff ────────────────────────────────────
        _offerRoute(
          pickupMeta: S.of(context).offerAway(
                etaToPickup,
                distToPickupMi.toStringAsFixed(1),
              ),
          pickupAddr: pickupAddr,
          dropoffMeta: S.of(context).offerTrip(
                tripEta,
                tripDistMi.toStringAsFixed(1),
              ),
          dropoffAddr: dropoffAddr,
        ),

        const SizedBox(height: 16),
        _offerDivider(),
        const SizedBox(height: 16),

        // ── Who is riding ───────────────────────────────────────────
        Row(
          children: [
            Expanded(
              child: Text(
                (offer['rider_name'] as String?) ?? S.of(context).riderFallback,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // A rider with no rating yet is a new rider — say so. The old
            // rule showed nothing at all in that case, which is how the
            // name ended up alone on the row with no way to tell whether
            // the rating was missing or the rider was.
            if (riderIsNew || !hasRating)
              Text(
                S.of(context).newRiderLabel,
                style: const TextStyle(
                  color: goldAccent,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              )
            else ...[
              const Icon(Icons.star_rounded, color: goldAccent, size: 15),
              const SizedBox(width: 3),
              Text(
                rating.toStringAsFixed(1),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),

        const SizedBox(height: 16),
        _offerDivider(),
        const SizedBox(height: 16),

        // ── Accept ──────────────────────────────────────────────────
        _buildAcceptButton(offer, offerId),
      ],
    );
  }

  /// The two stops on one rail, joined by a live gradient line.
  ///
  /// No panel behind them: the card is already a raised surface, and a
  /// second one inside it made the addresses read as a separate widget
  /// rather than as the trip the fare above is for. The line between the
  /// markers is what carries "these two are one journey" now that no box
  /// groups them.
  Widget _offerRoute({
    required String pickupMeta,
    required String pickupAddr,
    required String dropoffMeta,
    required String dropoffAddr,
  }) {
    const goldAccent = Color(0xFFE8C547);
    // Both stop blocks are given the same fixed height, so the markers can
    // be centred on them by arithmetic instead of by eye: half the block,
    // minus half the marker. Left to the text's natural height the two
    // would only line up by luck, and drift the moment a font changed.
    const halfPad = (_kOfferStopH - 11) / 2;
    // One box around the pair, not one around each. The two stops are a
    // single journey; a box each said they were two unrelated rows.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: neuBox(radius: 16),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 16,
              child: Column(
                children: [
                  const SizedBox(height: halfPad),
                  Container(
                    width: 11,
                    height: 11,
                    decoration: const BoxDecoration(
                      color: goldAccent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  // Expanded, so the rule runs to whatever height the
                  // addresses beside it actually take — a fixed height would
                  // break the moment one of them wrapped to two lines.
                  const Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: RouteConnectorLine(),
                    ),
                  ),
                  Container(
                    width: 11,
                    height: 11,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(2.5),
                    ),
                  ),
                  const SizedBox(height: halfPad),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _offerStopText(pickupMeta, pickupAddr),
                  const SizedBox(height: 22),
                  _offerStopText(dropoffMeta, dropoffAddr),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _offerDivider() => Container(
        height: 1,
        color: Colors.white.withValues(alpha: 0.05),
      );

  Widget _offerStopText(String meta, String address) {
    return SizedBox(
      height: _kOfferStopH,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            meta,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            address,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  /// A metric in its own raised pill.
  Widget _offerMetric(IconData icon, String value) {
    const goldAccent = Color(0xFFE8C547);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: neuBox(radius: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: goldAccent, size: 12),
          const SizedBox(width: 5),
          Text(
            value,
            style: const TextStyle(
              color: goldAccent,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  /// Responsive card height: adapts to screen so Accept button never gets cut.
  double _offerCardHeight(BuildContext context) {
    // Tight fit — no wasted space below the Accept button. The old
    // _ShimmerBadge row (Comfort/Premium/VIP) is gone so the base
    // height drops by ~22 px. We add per-badge allowance only when
    // the current offer actually shows badges per the new stack-of-
    // badges policy:
    //   immediate, card    → no badges
    //   immediate, cash    → 1 badge (CASH RIDE)
    //   scheduled          → 1+ badges (RESERVED [+ AIRPORT] [+ CASH])
    // The Wrap row stays at one line as long as the total stays under
    // ~3 badges, so a single 32-px allowance is enough.
    double extra = 0;
    if (_pendingOffers.isNotEmpty) {
      final safeIdx = _currentOfferIndex.clamp(
          0, (_pendingOffers.length - 1).clamp(0, 999));
      final offer = _pendingOffers[safeIdx];

      final raw = offer['scheduled_at'];
      bool isScheduled = false;
      if (raw != null) {
        final dt = DateTime.tryParse(raw.toString())?.toLocal();
        if (dt != null && dt.difference(DateTime.now()).inMinutes >= 3) {
          isScheduled = true;
        }
      }
      final paymentMethod = (offer['payment_method'] ??
              offer['paymentMethod'] ??
              offer['payment_type'] ??
              '')
          .toString()
          .toLowerCase();
      final isCash = paymentMethod == 'cash' || offer['is_cash'] == true;

      // Only scheduled trips OR immediate cash trips get a badge row.
      // Immediate card-paid trips (the most common case) use the
      // shortest layout with no extra height.
      final bool hasBadgeRow = isScheduled || isCash;
      if (hasBadgeRow) extra += 32;
      if (isScheduled) extra += 24; // scheduled time sublabel
    }
    // Every term of the card's height, so this stops drifting away from
    // the layout every time a gap changes. Text rows use Roboto's own
    // line height (~1.17 x the font size), which is what Flutter lays out
    // with — guessing "about 20" for a 15 px line is what left the Accept
    // button cut off once already.
    const double pad = 16 + 14;
    const double fareBlock = 35.2 + 4 + 14.6 + 10 + 26.1; // fare, rate, pills
    // + 24 for the box's own vertical padding.
    const double routeBlock = _kOfferStopH + 22 + _kOfferStopH + 24;
    const double divider = 16 + 1 + 16;
    const double riderRow = 17.6;
    const double accept = 48;
    // Enough that Accept is never clipped, no more. Every px here is dead
    // space under the button that pushes the whole card up the screen.
    const double slack = 12;
    const double base = pad +
        fareBlock +
        18 +
        routeBlock +
        divider +
        riderRow +
        divider +
        accept +
        slack;
    return base + extra;
  }

  Widget _buildAcceptButton(Map<String, dynamic> offer, String offerId) {
    final bool isAccepting = _offerAcceptState == _OfferAcceptState.routing &&
        _acceptingCardId == offerId;
    return GestureDetector(
      onTapDown:
          isAccepting ? null : (_) => _setState(() => _isAcceptPressed = true),
      onTapUp: isAccepting
          ? null
          : (_) {
              _setState(() => _isAcceptPressed = false);
              _acceptOffer(offer);
            },
      onTapCancel: () => _setState(() => _isAcceptPressed = false),
      child: AnimatedScale(
        scale: _isAcceptPressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: Container(
          width: double.infinity,
          height: 48,
          decoration: BoxDecoration(
            color: isAccepting
                ? const Color(0xFFD4A843).withValues(alpha: 0.5)
                : const Color(0xFFD4A843),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: isAccepting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation(Colors.black),
                    ),
                  )
                : Text(
                    S.of(context).accept,
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  /// Format a scheduled ride time relative to now — always 12-hour clock
  /// with AM/PM suffix (e.g. "8:15 PM"), never 24-hour. Localised via
  /// S.of(context) so the phone language picks ES vs EN.
  String _formatScheduledTime(DateTime dt) {
    final now = DateTime.now();
    final diff = dt.difference(now);
    final timeStr = _format12Hour(dt);
    final s = S.of(context);
    if (diff.isNegative) {
      return s.schedTimeNow(timeStr);
    } else if (diff.inMinutes <= 60) {
      return s.schedTimeInMinutes(timeStr, diff.inMinutes);
    } else if (diff.inHours <= 24) {
      return s.schedTimeInHours(timeStr, diff.inHours, diff.inMinutes % 60);
    } else {
      return s.schedTimeFutureDay(dt.day, dt.month - 1, timeStr);
    }
  }

  /// Returns "h:mm AM/PM" — 12-hour clock with zero-padded minutes.
  String _format12Hour(DateTime dt) {
    final int h24 = dt.hour;
    final int h12 = h24 == 0 ? 12 : (h24 > 12 ? h24 - 12 : h24);
    final String suffix = h24 < 12 ? 'AM' : 'PM';
    final String mm = dt.minute.toString().padLeft(2, '0');
    return '$h12:$mm $suffix';
  }

  /// Chip widget for time/distance display on offer card (compact).
  Widget _buildOfferChip({
    required IconData icon,
    required String value,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1F),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: const Color(0xFFE8C547), size: 12),
          const SizedBox(width: 5),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                label,
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem({
    required IconData icon,
    required String value,
    required String label,
  }) {
    const luxGold = Color(0xFFD4AF37);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: luxGold, size: 16),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              label,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ],
    );
  }

  Widget _uberAddressRow({
    required IconData icon,
    required Color iconColor,
    required double iconSize,
    required String topLine,
    required String bottomLine,
    required bool showConnector,
    bool darkMode = false,
  }) {
    final subColor = darkMode
        ? Colors.white.withValues(alpha: 0.45)
        : const Color(0xFF666666);
    final mainColor = darkMode ? Colors.white : const Color(0xFF1A1A1F);
    final lineColor = darkMode
        ? Colors.white.withValues(alpha: 0.15)
        : const Color(0xFFCCCCCC);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Icon + connector line column
        SizedBox(
          width: 20,
          child: Column(
            children: [
              const SizedBox(height: 4),
              Icon(icon, color: iconColor, size: iconSize),
              if (showConnector)
                Container(
                  width: 1.5,
                  height: 36,
                  color: lineColor,
                  margin: const EdgeInsets.symmetric(vertical: 3),
                ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                topLine,
                style: TextStyle(
                  color: subColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                bottomLine,
                style: TextStyle(
                  color: mainColor,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (showConnector) const SizedBox(height: 10),
            ],
          ),
        ),
      ],
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  ROUTE PREVIEW PANEL (shown when tapping an offer card)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _routePreviewPanel(bool isDark) {
    final offer = _previewingOffer!;
    final name =
        (offer['rider_name'] as String?) ?? S.of(context).riderFallback;
    final init = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final rating = _safeDouble(offer['rider_rating']);
    final ratingsCount = _safeDouble(offer['rider_ratings_count']).toInt();
    final riderIsNew = offer['rider_is_new'] == true;
    final hasRating = !riderIsNew && ratingsCount > 0 && rating > 0;
    final fare = _safeDouble(offer['fare']);
    final rawPickupAddr2 =
        (offer['pickup_address'] as String?) ?? S.of(context).pickupFallback;
    final dropoffAddr =
        (offer['dropoff_address'] as String?) ?? S.of(context).dropoffFallback;
    final pickupLat = _safeDouble(offer['pickup_lat']);
    final pickupLng = _safeDouble(offer['pickup_lng']);
    final dropoffLat = _safeDouble(offer['dropoff_lat']);
    final dropoffLng = _safeDouble(offer['dropoff_lng']);
    final pickupLL = LatLng(pickupLat, pickupLng);
    final dropoffLL = LatLng(dropoffLat, dropoffLng);
    final vehicleType =
        _mapRideType((offer['vehicle_type'] ?? 'Comfort') as String);
    final pickupAddr = _isGenericAddress(rawPickupAddr2)
        ? (_resolvedAddressCache['${pickupLat}_$pickupLng'] ?? rawPickupAddr2)
        : rawPickupAddr2;
    final previewOfferId =
        (offer['offer_id'] ?? offer['id'] ?? '${pickupLat}_$pickupLng')
            .toString();
    final cachedPreview = _routeCache[previewOfferId];
    final int etaToPickup;
    final int tripEta;
    final double distToPickupMi;
    final double tripDistMi;
    if (cachedPreview?.driverToPickupKm != null &&
        cachedPreview?.pickupToDropoffKm != null) {
      etaToPickup = (cachedPreview!.driverToPickupMin ?? 1).ceil().clamp(1, 99);
      distToPickupMi = cachedPreview.driverToPickupKm! * 0.621371;
      tripEta = (cachedPreview.pickupToDropoffMin ?? 1).ceil().clamp(1, 99);
      tripDistMi = cachedPreview.pickupToDropoffKm! * 0.621371;
    } else {
      if (_pos != null) {
        final distToPickupKm = _hav(_pos!, pickupLL);
        final safeDist = distToPickupKm.isFinite ? distToPickupKm : 0.0;
        etaToPickup = (safeDist * 1000 / 17.88 / 60).ceil().clamp(1, 99);
        distToPickupMi = safeDist * 0.621371;
      } else {
        etaToPickup = 1;
        distToPickupMi = 0;
      }
      final tripDistKm = _hav(pickupLL, dropoffLL);
      final safeTripDist = tripDistKm.isFinite ? tripDistKm : 0.0;
      tripEta = (safeTripDist * 1000 / 17.88 / 60).ceil().clamp(1, 99);
      tripDistMi = safeTripDist * 0.621371;
    }

    const cCardBg = Color(0xFF1A1A1F); // ignore: unused_local_variable
    const cTextPrimary = Colors.white;
    final cTextMuted = Colors.white.withValues(alpha: 0.5);
    final cBorderC = Colors.white.withValues(alpha: 0.06);
    final chipBg = Colors.white.withValues(alpha: 0.04);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0A).withValues(alpha: 0.97),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 24,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Handle
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // â”€â”€ Top row: Avatar + Name + Fare â”€â”€
                  Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: _gold.withValues(alpha: 0.11),
                          borderRadius: BorderRadius.circular(13),
                          border: Border.all(
                            color: _gold.withValues(alpha: 0.28),
                          ),
                        ),
                        child: const Icon(
                          Icons.directions_car_rounded,
                          color: _gold,
                          size: 23,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              vehicleType,
                              style: const TextStyle(
                                color: cTextPrimary,
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (riderIsNew || hasRating)
                              const SizedBox(height: 5),
                            if (riderIsNew)
                              Text(
                                S.of(context).newRiderLabel,
                                style: const TextStyle(
                                  color: _gold,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              )
                            else if (hasRating)
                              Row(
                                children: [
                                  const Icon(Icons.star_rounded,
                                      color: _gold, size: 13),
                                  const SizedBox(width: 3),
                                  Text(
                                    rating.toStringAsFixed(1),
                                    style: const TextStyle(
                                      color: _gold,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: _gold.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: _gold.withValues(alpha: 0.2),
                          ),
                        ),
                        child: Text(
                          '\$${fare.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // â”€â”€ Info chips â”€â”€
                  Row(
                    children: [
                      _infoChip(
                        Icons.near_me_rounded,
                        '${distToPickupMi.toStringAsFixed(1)} mi',
                        chipBg,
                        cTextMuted,
                      ),
                      const SizedBox(width: 8),
                      _infoChip(
                        Icons.timer_rounded,
                        '$etaToPickup min',
                        chipBg,
                        cTextMuted,
                      ),
                      const SizedBox(width: 8),
                      _infoChip(
                        Icons.route_rounded,
                        '${tripDistMi.toStringAsFixed(1)} mi trip',
                        chipBg,
                        cTextMuted,
                      ),
                      const SizedBox(width: 8),
                      _infoChip(
                        Icons.schedule_rounded,
                        '$tripEta min',
                        chipBg,
                        cTextMuted,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // â”€â”€ Route: Driver â†’ Pickup â†’ Dropoff â”€â”€
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.02),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: cBorderC),
                    ),
                    child: Column(
                      children: [
                        // Driver location
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              children: [
                                Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.blueAccent,
                                      width: 2,
                                    ),
                                  ),
                                ),
                                Container(
                                  width: 1.5,
                                  height: 20,
                                  color: cBorderC,
                                ),
                              ],
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    S.of(context).yourLocation,
                                    style: TextStyle(
                                      color: cTextMuted,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  Text(
                                    S.of(context).currentPosition,
                                    style: const TextStyle(
                                      color: cTextPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        // Pickup
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              children: [
                                Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.greenAccent,
                                      width: 2,
                                    ),
                                  ),
                                ),
                                Container(
                                  width: 1.5,
                                  height: 20,
                                  color: cBorderC,
                                ),
                              ],
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    S.of(context).pickupLabel,
                                    style: TextStyle(
                                      color: cTextMuted,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  Text(
                                    pickupAddr,
                                    style: const TextStyle(
                                      color: cTextPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        // Dropoff
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white54,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    S.of(context).dropOffLabel,
                                    style: TextStyle(
                                      color: cTextMuted,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  Text(
                                    dropoffAddr,
                                    style: const TextStyle(
                                      color: cTextPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // â”€â”€ Action buttons: Back + Accept â”€â”€
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: OutlinedButton.icon(
                            onPressed: () {
                              _closePreview();
                            },
                            icon: const Icon(
                              Icons.arrow_back_rounded,
                              color: Colors.white70,
                              size: 18,
                            ),
                            label: Text(
                              S.of(context).back,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.06,
                              ),
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.12),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: SizedBox(
                          height: 48,
                          child: ElevatedButton.icon(
                            onPressed: () {
                              _acceptOffer(offer);
                            },
                            icon: const Icon(
                              Icons.check_rounded,
                              color: Colors.black,
                              size: 18,
                            ),
                            label: Text(
                              S.of(context).acceptRide,
                              style: const TextStyle(
                                color: Colors.black,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _gold,
                              foregroundColor: Colors.black,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
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
        ),
      ),
    );
  }

  Widget _infoChip(IconData ic, String txt, Color bg, Color textColor) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(ic, size: 14, color: _gold.withValues(alpha: 0.7)),
            const SizedBox(height: 2),
            Text(
              txt,
              style: TextStyle(
                color: textColor,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(IconData ic, String txt, Color c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.withValues(alpha: 0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ic, size: 12, color: c),
          const SizedBox(width: 4),
          Text(
            txt,
            style: TextStyle(
              color: c,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryBadge(IconData icon, String text, Color primary, Color muted) {
    return Column(
      children: [
        Icon(icon, color: _gold, size: 20),
        const SizedBox(height: 4),
        Text(
          text,
          style: TextStyle(
            color: primary,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  // â”€â”€ IN-TRIP PANEL â”€â”€
  // NAV STAT CHIP (icon + label, used in Google Maps-style ETA strip)
  Widget _navStat(IconData icon, String value, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 13),
        const SizedBox(width: 4),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  // â”€â”€ COMPLETED OVERLAY â”€â”€
  Widget _completedOverlay(
    bool isDark,
    Color overlayBg,
    Color card,
    Color textPrimary,
    Color borderC,
    Color shadowC,
  ) {
    final subtleText = isDark
        ? Colors.white.withValues(alpha: 0.35)
        : Colors.black.withValues(alpha: 0.35);
    final subtleBg = isDark
        ? Colors.white.withValues(alpha: 0.03)
        : Colors.black.withValues(alpha: 0.04);

    return GestureDetector(
      onTap: () {},
      child: Container(
        color: overlayBg,
        child: Center(
          child: FadeTransition(
            opacity: _doneScale ?? const AlwaysStoppedAnimation(0.0),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: card,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: _gold.withValues(alpha: 0.2)),
                boxShadow: [
                  BoxShadow(
                    color: _gold.withValues(alpha: 0.08),
                    blurRadius: 40,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          _gold.withValues(alpha: 0.15),
                          _gold.withValues(alpha: 0.05),
                        ],
                      ),
                      border: Border.all(
                        color: _gold.withValues(alpha: 0.3),
                        width: 2,
                      ),
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      color: _gold,
                      size: 38,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    S.of(context).tripComplete,
                    style: TextStyle(
                      color: textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Fare
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _gold.withValues(alpha: 0.1)),
                    ),
                    child: Column(
                      children: [
                        Text(
                          '\$${_fare.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 36,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          S.of(context).fareEarned,
                          style: TextStyle(color: subtleText, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Rating
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: subtleBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Text(
                          S.of(context).rateRider,
                          style: TextStyle(color: subtleText, fontSize: 11),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(
                            5,
                            (i) => GestureDetector(
                              onTap: () {
                                HapticService.selectionClick();
                                _setState(() => _stars = i + 1);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 3,
                                ),
                                child: Icon(
                                  Icons.star_rounded,
                                  color: i < _stars
                                      ? _gold
                                      : _gold.withValues(alpha: 0.15),
                                  size: 30,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Session summary
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _sumStat(
                        '\$${_earnings.toStringAsFixed(2)}',
                        S.of(context).totalLabel,
                        textPrimary,
                        subtleText,
                      ),
                      _sumStat(
                        '$_trips',
                        S.of(context).tripsLabel,
                        textPrimary,
                        subtleText,
                      ),
                      _sumStat(
                        _timeStr,
                        S.of(context).onlineLabel,
                        textPrimary,
                        subtleText,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _afterComplete,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 4,
                        shadowColor: _gold.withValues(alpha: 0.3),
                      ),
                      child: Text(
                        S.of(context).continueDriving,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  ONLINE PANEL (draggable with GO OFFLINE)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _showOnlinePanel() {
    _animatePanelTo(_panelOpen ? 0.0 : 1.0);
  }

  void _animatePanelTo(double target) {
    final from = _panelFrac;
    final dist = (target - from).abs();
    // Speed proportional to distance — minimum 180ms, max 400ms
    final ms = (180 + dist * 220).round().clamp(180, 400);
    _panelAnimCtrl?.dispose();
    _panelAnimCtrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: ms),
    );
    _panelAnim = Tween<double>(begin: from, end: target).animate(
      CurvedAnimation(parent: _panelAnimCtrl!, curve: Curves.easeOutCubic),
    );
    _panelAnim!.addListener(() {
      _setState(() => _panelFrac = _panelAnim!.value);
    });
    _panelAnimCtrl!.forward().then((_) {
      if (!mounted) return;
      _setState(() {
        _panelOpen = target > 0.5;
        // Back to the money when it closes. Reserved is somewhere the driver
        // went, not a state the panel should still be in next time they pull
        // it up.
        if (!_panelOpen) _panelShowsReserve = false;
      });
    });
  }

  Widget _floatingPanel(
    bool isDark,
    Color surface,
    Color textMuted,
    Color borderC,
    Color textPrimary,
    Color shadowC,
  ) {
    final screenH = MediaQuery.of(context).size.height;
    final botPad = MediaQuery.of(context).padding.bottom;
    final t = _panelFrac.clamp(0.0, 1.0);

    // Collapsed pill height + expanded max height.
    //
    // 0.82, not 0.55. The panel used to hold three one-line links and 55%
    // of the screen was plenty; it now holds the earnings card, the chart,
    // two counters, the promotions row and the button that ends the shift
    // — 617 px of content. At 55% of a 844 pt phone that is 464, so the
    // last two items were below the fold on every handset, and the one
    // control that goes offline was the first thing to fall off.
    //
    // 0.82 is the same ceiling the offers sheet in this file uses, and it
    // still leaves the map showing above the panel. Short phones scroll —
    // the list inside was always scrollable.
    //
    // The collapsed pill used to float — 12 px of map either side and 10
    // above the home indicator, with all four corners rounded. It is the
    // same sheet as "You're offline" on the home screen, one tap earlier in
    // the shift, so it now sits the same way: welded to both sides and to
    // the bottom edge, top corners only. Going online should move the
    // driver forward, not slide the furniture around.
    final collapsedH = 78.0 + botPad;
    final expandedH = screenH * 0.82;
    final currentH = collapsedH + (expandedH - collapsedH) * t;

    // 26, the radius _buildDraggablePanel uses on the home screen.
    const radius = BorderRadius.vertical(top: Radius.circular(26));

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      height: currentH,
      child: GestureDetector(
        onVerticalDragUpdate: (d) {
          // Finger controls: dragging up increases frac, down decreases
          final delta = -d.delta.dy / (expandedH - collapsedH);
          _setState(() {
            _panelFrac = (_panelFrac + delta).clamp(0.0, 1.0);
          });
        },
        onVerticalDragEnd: (d) {
          // Velocity-aware snap: fast flick snaps immediately
          final velocity = d.primaryVelocity ?? 0;
          double target;
          if (velocity < -300) {
            target = 1.0; // fast swipe up → open
          } else if (velocity > 300) {
            target = 0.0; // fast swipe down → close
          } else {
            target = _panelFrac > 0.35 ? 1.0 : 0.0; // finger position snap
          }
          _animatePanelTo(target);
        },
        child: ListenableBuilder(
          listenable: _searchPulseVal,
          builder: (_, child) => CustomPaint(
            foregroundPainter: _SearchingBorderPainter(
              progress: _searchPulseVal.value,
              // Hands the light over to the divider as the sheet opens.
              expansion: t,
            ),
            child: child,
          ),
          child: Container(
            // Raised neumorphic sheet. neuBox() can't be used directly here —
            // the corner radius animates with the drag fraction — so the neu
            // tokens and its shadow pair are applied by hand.
            decoration: BoxDecoration(
              color: isDark ? neuSurface : surface,
              borderRadius: radius,
              border: isDark
                  ? Border.all(color: Colors.white.withValues(alpha: 0.04))
                  : null,
              boxShadow: isDark
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.55),
                        offset: const Offset(6, 6),
                        blurRadius: 14,
                      ),
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.045),
                        offset: const Offset(-4, -4),
                        blurRadius: 10,
                      ),
                    ]
                  : [
                      BoxShadow(
                        color: shadowC,
                        blurRadius: 20,
                        offset: const Offset(0, -4),
                      ),
                    ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                const SizedBox(height: 8),
                _handle(isDark),
                // Arrow icon: up when collapsed, down when expanded
                Icon(
                  t > 0.5
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_up_rounded,
                  color: textMuted.withValues(alpha: 0.5),
                  size: 16,
                ),
                // Header row — icons sit in sunken neu wells
                SizedBox(
                  height: 34,
                  child: Row(
                    children: [
                      const SizedBox(width: 14),
                      // Safety on the left, Reserved on the right — only here,
                      // in the open panel, where each has room for a word.
                      _panelAction(
                        Icons.health_and_safety_outlined,
                        isDark,
                        textMuted,
                        active: false,
                        semanticLabel: S.of(context).safetyHub,
                        onTap: () {
                          HapticService.selectionClick();
                          Navigator.push(
                            context,
                            slideFromRightRoute(const SafetyScreen()),
                          );
                        },
                      ),
                      const Spacer(),
                      // The alternating status, not a fixed word.
                      //
                      // This is the header the driver reads while waiting —
                      // _floatingPanel is what the searching phase renders.
                      // The label had been written into _searchingBar and into
                      // the offers sheet, neither of which is on screen here.
                      _searchingLabel(textMuted),
                      const Spacer(),
                      _panelAction(
                        Icons.event_available_rounded,
                        isDark,
                        textMuted,
                        active: _panelShowsReserve,
                        badge: _scheduledAvailCount,
                        semanticLabel: S.of(context).reservedLabel,
                        onTap: () {
                          HapticService.selectionClick();
                          // Swaps the body below, in place. Reserved rides are
                          // a different answer to the same question the panel
                          // is already answering — not another screen.
                          _setState(
                              () => _panelShowsReserve = !_panelShowsReserve);
                          if (_panelShowsReserve) _fetchScheduledCount();
                        },
                      ),
                      const SizedBox(width: 14),
                    ],
                  ),
                ),
                // The divider, and the travelling light that now lives on it.
                //
                // Fixed here in the Column rather than scrolled with the list.
                // It is the rule between the header and the content, so it
                // belongs to the header — and a light that slides off the top
                // of the screen the moment the driver scrolls is not an
                // indicator of anything.
                //
                // Its own ListenableBuilder: the pulse ticks sixty times a
                // second, and the builder above deliberately passes the whole
                // sheet through as `child` so none of it rebuilds at that
                // rate. This is the one part that has to.
                if (t > 0.05) ...[
                  const SizedBox(height: 12),
                  Opacity(
                    opacity: t.clamp(0.0, 1.0),
                    child: ListenableBuilder(
                      listenable: _searchPulseVal,
                      builder: (_, __) => _SearchingDividerLine(
                        progress: _searchPulseVal.value,
                        baseColor: borderC,
                      ),
                    ),
                  ),
                ],
                // Expanded content fades in
                if (t > 0.05)
                  Expanded(
                    child: Opacity(
                      opacity: t.clamp(0.0, 1.0),
                      child: ListView(
                        padding: EdgeInsets.zero,
                        physics: t > 0.8
                            ? const ClampingScrollPhysics()
                            : const NeverScrollableScrollPhysics(),
                        children: [
                          const SizedBox(height: 18),
                          // "Earnings", not "Recommended for you".
                          //
                          // The old heading introduced three links to other
                          // screens. What follows it now is the figures
                          // themselves, and a heading that promises
                          // recommendations above a bar chart is just wrong.
                          // Left-aligned and small, the same label the home
                          // sheet puts over the same card.
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 18),
                            child: Text(
                              // The slot below crosses between the figures
                              // and the reservations. A heading fixed on
                              // "EARNINGS" over a list of scheduled rides
                              // is the same mistake the old
                              // "Recommended for you" made.
                              (_panelShowsReserve
                                      ? S.of(context).scheduledRidesTitle
                                      : S.of(context).earningsTitle)
                                  .toUpperCase(),
                              style: TextStyle(
                                fontFamily: 'Poppins',
                                color: Colors.white.withValues(alpha: 0.45),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.4,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          // Earnings, or the reserved rides — the same slot,
                          // crossed over rather than swapped, and the height
                          // eased so the button below never jumps.
                          AnimatedSize(
                            duration: const Duration(milliseconds: 420),
                            curve: Curves.easeInOutCubicEmphasized,
                            alignment: Alignment.topCenter,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 340),
                              switchInCurve: Curves.easeOutCubic,
                              switchOutCurve: Curves.easeIn,
                              layoutBuilder: (current, previous) => Stack(
                                alignment: Alignment.topCenter,
                                children: [
                                  ...previous,
                                  if (current != null) current,
                                ],
                              ),
                              child: _panelShowsReserve
                                  ? KeyedSubtree(
                                      key: const ValueKey('reserve'),
                                      child: _panelReserveBody(isDark),
                                    )
                                  : KeyedSubtree(
                                      key: const ValueKey('earnings'),
                                      child:
                                          _panelEarningsBody(isDark, borderC),
                                    ),
                            ),
                          ),
                          // Reserved by the pinned button below now.
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  )
                else
                  const Spacer(),
                // Pinned, not scrolled.
                //
                // This is the one control that ends the shift, and it was
                // the last row of the list — so on a short panel it sat
                // wherever the content happened to stop, and on a long one
                // the driver had to scroll to reach it. A button that ends
                // the working day belongs in the same place every time it
                // is looked for.
                if (t > 0.05)
                  Opacity(
                    opacity: t.clamp(0.0, 1.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // A clear gap before the one button that ends the
                        // shift, so it never reads as another row in the list
                        // above it.
                        const SizedBox(height: 26),
                        // GO OFFLINE button — raised neu disc, red accent
                        Center(
                          child: GestureDetector(
                            onTap: _goOffline,
                            child: Column(
                              children: [
                                Container(
                                  width: 62,
                                  height: 62,
                                  alignment: Alignment.center,
                                  decoration: isDark
                                      ? neuBox(
                                          radius: 31,
                                          borderColor: const Color(
                                            0xFFCC3333,
                                          ).withValues(alpha: 0.35),
                                          borderWidth: 1.5,
                                        )
                                      : BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: const Color(
                                            0xFFCC3333,
                                          ).withValues(alpha: 0.15),
                                          border: Border.all(
                                            color: const Color(
                                              0xFFCC3333,
                                            ).withValues(alpha: 0.3),
                                            width: 2,
                                          ),
                                        ),
                                  child: const Icon(
                                    Icons.pan_tool_rounded,
                                    color: Color(0xFFCC3333),
                                    size: 26,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  S.of(context).goOffline.toUpperCase(),
                                  style: const TextStyle(
                                    color: Color(0xFFCC3333),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        // Just the home indicator's own space. The 20 px
                        // on top of it left the button floating above a
                        // band of nothing at the foot of the panel.
                        SizedBox(height: botPad),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Time online as a clock, not a decimal — same rule as the home sheet.
  String _onlineTimeText(double hours) {
    if (!hours.isFinite || hours <= 0) return '0h';
    final totalMinutes = (hours * 60).round();
    final h = totalMinutes ~/ 60;
    final m = totalMinutes % 60;
    if (h == 0) return '${m}min';
    if (m == 0) return '${h}h';
    return '${h}h ${m}min';
  }

  /// One counter — trips today, or time online.
  Widget _panelStat(IconData icon, String value, String label, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: isDark
          ? neuBox(radius: 18)
          : BoxDecoration(
              color: Colors.black.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(18),
            ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: neuBox(radius: 10, pressed: true),
            alignment: Alignment.center,
            child: Icon(icon, size: 15, color: _gold),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontFamily: 'Poppins',
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w800,
              fontFeatures: [ui.FontFeature.tabularFigures()],
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'Poppins',
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// Earnings, with the day or the week drawn underneath.
  ///
  /// A plain row of rectangles rather than a chart package: the panel is
  /// already the heaviest thing on this screen, and a dependency for two
  /// dozen bars would cost a native rebuild to ship.
  Widget _panelEarningsCard(bool isDark, Color borderC) {
    final week = _panelWeekTab;
    final values = week ? _daySeries : _hourlySeries;
    final total = week ? _weeklyEarnings : _earnings;
    const barH = 74.0;
    final peak = values.fold<double>(0, math.max);
    final labels = week
        ? _daySeriesLabels
        : const [
            '12AM',
            '',
            '',
            '',
            '',
            '',
            '6AM',
            '',
            '',
            '',
            '',
            '',
            '12PM',
            '',
            '',
            '',
            '',
            '',
            '6PM',
            '',
            '',
            '',
            '',
            ''
          ];

    Widget tab(String text, bool on, VoidCallback onTap) {
      return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: on
              ? BoxDecoration(
                  color: _gold.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                )
              : null,
          child: Text(
            text,
            style: TextStyle(
              fontFamily: 'Poppins',
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: on ? _gold : Colors.white.withValues(alpha: 0.45),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: isDark
          ? neuBox(radius: 18)
          : BoxDecoration(
              color: Colors.black.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(18),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              tab(S.of(context).today, !week,
                  () => _setState(() => _panelWeekTab = false)),
              const SizedBox(width: 6),
              tab(S.of(context).weekLabel, week,
                  () => _setState(() => _panelWeekTab = true)),
              const Spacer(),
              Text(
                '\$${total.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  fontFeatures: [ui.FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // The axis draws even with no data — a floor of 3% on every bar,
          // so an empty day reads as "nothing yet" instead of as broken.
          SizedBox(
            // The week keeps a band above the tallest bar for its amount.
            // Taken out of the card rather than out of the bars, so adding
            // the figures does not shorten the chart they sit on.
            height: week ? barH + _kBarTipH : barH,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (int i = 0; i < (week ? 7 : 24); i++) ...[
                  if (i > 0) SizedBox(width: week ? 7 : 2),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        // The amount, riding on the tip of its own bar.
                        //
                        // Only where there is money: a row of $0.00 under
                        // every empty day is noise standing exactly where
                        // the eye goes to compare the days that earned.
                        //
                        // Scaled down rather than clipped — seven columns on
                        // a narrow phone leave about 40 px each, and a good
                        // Saturday is wider than that.
                        if (week)
                          SizedBox(
                            height: _kBarTipH,
                            child: (i < values.length && values[i] > 0)
                                ? FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      '\$${values[i].toStringAsFixed(2)}',
                                      maxLines: 1,
                                      style: TextStyle(
                                        fontFamily: 'Poppins',
                                        color: _gold.withValues(alpha: 0.85),
                                        fontSize: 9,
                                        fontWeight: FontWeight.w700,
                                        fontFeatures: const [
                                          ui.FontFeature.tabularFigures()
                                        ],
                                      ),
                                    ),
                                  )
                                : null,
                          ),
                        Container(
                          width: week ? 10 : 4,
                          height: barH *
                              (i < values.length && peak > 0
                                  ? math.max(0.03, values[i] / peak)
                                  : 0.03),
                          decoration: BoxDecoration(
                            color: _gold.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (int i = 0; i < (week ? 7 : 24); i++) ...[
                if (i > 0) SizedBox(width: week ? 7 : 2),
                Expanded(
                  child: Text(
                    i < labels.length ? labels[i] : '',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    softWrap: false,
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      color: Colors.white.withValues(alpha: 0.3),
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// The searching label: three dots that count up, and a highlight that
  /// sweeps the width of the words.
  ///
  /// It sits in the middle of the panel header, between the two icons, and
  /// the sweep is sized to the text rather than to the bar — from the first
  /// letter to the last dot. A fixed word would be read once and then
  /// ignored; two that trade places under something that moves keep saying
  /// the machine is still working, which is the one thing the driver wants
  /// to know while nothing is happening.
  ///
  /// Everything rides the 3 s pulse that already drives the border, so no
  /// second ticker is started for this.
  Widget _searchingLabel(Color textMuted) {
    return AnimatedBuilder(
      animation: _searchPulseVal,
      builder: (context, _) {
        final p = _searchPulseVal.value; // 0..1, three seconds per lap
        // One dot per second: 1, 2, 3, repeat.
        final dots = 1 + (p * 3).floor().clamp(0, 2);
        final text = _statusLine == 0
            ? S.of(context).findingTrips
            : S.of(context).youreOnlineStatus;

        // The width eases too.
        //
        // "You're online" is narrower than "Finding trips", so without this
        // the block snapped to its new width the instant the switch
        // finished — a jump at the end of an otherwise smooth fade, and the
        // sweep rail underneath jumped with it.
        return AnimatedSize(
          duration: const Duration(milliseconds: 520),
          curve: Curves.easeInOutCubicEmphasized,
          alignment: Alignment.centerLeft,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 520),
            // Material's emphasized easing, the same one the rider's vehicle
            // row uses: leaves slowly, arrives slowly. A short slide, because
            // a long one on two words reads as a card being dealt.
            switchInCurve: Curves.easeInOutCubicEmphasized,
            switchOutCurve: Curves.easeInOutCubicEmphasized,
            // Stacked and centred, so the outgoing line holds its place while
            // it fades instead of collapsing and shoving the incoming one.
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.centerLeft,
              children: [
                ...previous,
                if (current != null) current,
              ],
            ),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.18),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            child: IntrinsicWidth(
              key: ValueKey<int>(_statusLine),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$text${'.' * dots}',
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    // Read as loudly as "You're offline" does on the home
                    // sheet, which is the same sentence about the same driver
                    // in the opposite state. It was drawn in the muted grey
                    // the icons beside it use, so the one line saying what the
                    // app is doing was dimmer than the furniture around it.
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  // The sweep bar that used to sit under these words is
                  // gone. The same travelling light runs the divider below
                  // the header now — one indicator on a longer track,
                  // instead of a second one three pixels under the text.
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// A labelled control in the panel's header. Icon over a word, in a
  /// sunken well, with an optional count.
  Widget _panelAction(
    IconData icon,
    bool isDark,
    Color textMuted, {
    required bool active,
    required VoidCallback onTap,
    required String semanticLabel,
    int badge = 0,
  }) {
    final tint = active ? _gold : textMuted;
    // The label the icon dropped has to go somewhere. Nothing on screen
    // says what these two do, so without this a screen reader announces
    // two unnamed buttons.
    return Semantics(
      button: true,
      label: badge > 0 ? '$semanticLabel, $badge' : semanticLabel,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 38,
          height: 34,
          alignment: Alignment.center,
          decoration: isDark
              ? neuBox(
                  radius: 14,
                  pressed: true,
                  borderColor: active ? _gold.withValues(alpha: 0.45) : null,
                  borderWidth: active ? 1 : 0,
                )
              : BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(14),
                ),
          // The icon alone. Two words in a 34 px header crowded the status
          // out of the middle, and both symbols are ones the driver already
          // knows from the buttons on the map behind this panel.
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Icon(icon, size: 19, color: tint),
              if (badge > 0)
                Positioned(
                  top: -3,
                  right: -5,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 15),
                    height: 15,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _gold,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$badge',
                      style: const TextStyle(
                        fontFamily: 'Poppins',
                        color: Color(0xFF0B0B0F),
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
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

  /// The default panel body: the money, the two counters, and the one link
  /// that goes somewhere this panel cannot show inline.
  Widget _panelEarningsBody(bool isDark, Color borderC) {
    final panelItemIcon = isDark ? _gold : Colors.black.withValues(alpha: 0.55);
    final panelItemText =
        isDark ? Colors.white.withValues(alpha: 0.7) : Colors.black87;
    final panelItemChevron = isDark
        ? Colors.white.withValues(alpha: 0.25)
        : Colors.black.withValues(alpha: 0.25);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: _panelEarningsCard(isDark, borderC),
        ),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Expanded(
                child: _panelStat(
                  Icons.local_taxi_rounded,
                  '$_tripsToday',
                  S.of(context).tripsToday,
                  isDark,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _panelStat(
                  Icons.schedule_rounded,
                  _onlineTimeText(_hoursToday),
                  S.of(context).hoursOnline,
                  isDark,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The reserved-rides body: what is bookable near the driver, or the fact
  /// that nothing is.
  Widget _panelReserveBody(bool isDark) {
    final none = _scheduledAvailCount <= 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 18),
        decoration: isDark
            ? neuBox(radius: 18)
            : BoxDecoration(
                color: Colors.black.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(18),
              ),
        child: Column(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: neuBox(radius: 15, pressed: true),
              alignment: Alignment.center,
              child: Icon(
                none ? Icons.event_busy_rounded : Icons.event_available_rounded,
                size: 21,
                color: none ? Colors.white.withValues(alpha: 0.35) : _gold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              none
                  ? S.of(context).noScheduledNearby
                  : '$_scheduledAvailCount '
                      '${_scheduledAvailCount == 1 ? S.of(context).scheduledNearbyCountOne : S.of(context).scheduledNearbyCount}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              // Each half of the card gets its own line. The "we'll tell you
              // when one turns up" copy sat under both, so it contradicted
              // the count it was printed beneath.
              none
                  ? S.of(context).noScheduledNearbySub
                  : S.of(context).scheduledNearbySub,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                height: 1.35,
              ),
            ),
            if (!none) ...[
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () {
                  HapticService.selectionClick();
                  Navigator.push(
                    context,
                    slideFromRightRoute(
                        const ScheduledRidesScreen(initialTab: 0)),
                  ).then((_) => _fetchScheduledCount());
                },
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: neuBox(radius: 14),
                  child: Text(
                    S.of(context).viewAllScheduled,
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      color: _gold,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Small sunken neu well holding a single icon (panel header controls).
  Widget _panelWell(IconData ic, bool isDark, Color iconC) {
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: isDark
          ? neuBox(radius: 11, pressed: true)
          : BoxDecoration(
              color: Colors.black.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(11),
            ),
      child: Icon(ic, color: iconC, size: 19),
    );
  }

  Widget _panelItem(
    IconData ic,
    String txt,
    Color iconC,
    Color textC,
    Color chevronC,
    VoidCallback tap,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () {
        HapticService.selectionClick();
        tap();
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: isDark
                  ? neuBox(radius: 13, pressed: true)
                  : BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(13),
                    ),
              child: Icon(ic, color: _gold, size: 20),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Text(
                txt,
                style: TextStyle(
                  color: textC,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: chevronC, size: 20),
          ],
        ),
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  SHARED WIDGETS
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _slideToAction(
    String label,
    Color c,
    bool isDark,
    VoidCallback onDone,
  ) {
    final labelColor = isDark
        ? Colors.white.withValues(alpha: 0.35)
        : Colors.black.withValues(alpha: 0.30);

    return StatefulBuilder(
      builder: (ctx, setLocal) {
        return Container(
          height: 56,
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: c.withValues(alpha: 0.18), width: 1.5),
          ),
          child: LayoutBuilder(
            builder: (_, cons) {
              final max = cons.maxWidth - 60;
              return Stack(
                children: [
                  Center(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: labelColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: FractionallySizedBox(
                        widthFactor: _slideVal,
                        alignment: Alignment.centerLeft,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                c.withValues(alpha: 0.12),
                                c.withValues(alpha: 0.0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: _slideVal * max + 4,
                    top: 4,
                    bottom: 4,
                    child: GestureDetector(
                      onHorizontalDragUpdate: (d) {
                        setLocal(() {
                          _slideVal += d.delta.dx / max;
                          _slideVal = _slideVal.clamp(0.0, 1.0);
                        });
                        if (_slideVal >= 0.88 && !_slid) {
                          _slid = true;
                          HapticService.heavyImpact();
                          onDone();
                        }
                      },
                      onHorizontalDragEnd: (_) {
                        if (!_slid) setLocal(() => _slideVal = 0);
                      },
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: c.withValues(alpha: 0.35),
                              blurRadius: 10,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.chevron_right_rounded,
                          color: Colors.black,
                          size: 26,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _bottomSheet(bool isDark, Color bg, Color shadowC, Widget child) {
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: _gold.withValues(alpha: 0.08))),
        boxShadow: [
          BoxShadow(
            color: shadowC,
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: child,
        ),
      ),
    );
  }

  Widget _wrapInDraggableSheet({
    required bool isDark,
    required Color surface,
    required Color shadowC,
    required Widget child,
    double minChildSize = 0.18,
  }) {
    final screenH = MediaQuery.of(context).size.height;
    return SizedBox(
      height: screenH,
      child: DraggableScrollableSheet(
        initialChildSize: minChildSize,
        minChildSize: minChildSize,
        maxChildSize: 0.85,
        snap: true,
        snapSizes: [minChildSize, 0.55, 0.85],
        builder: (ctx, scrollCtrl) {
          return Container(
            decoration: BoxDecoration(
              color: surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(
                top: BorderSide(color: _gold.withValues(alpha: 0.08)),
              ),
              boxShadow: [
                BoxShadow(
                  color: shadowC,
                  blurRadius: 20,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
            child: ListView(
              controller: scrollCtrl,
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.zero,
              children: [
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                    child: child,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _handle(bool isDark) => Center(
        child: Container(
          width: 40,
          height: 5,
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.25)
                : Colors.black.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      );

  Widget _fab(
    IconData ic,
    double sz,
    Color bg,
    Color border,
    Color iconColor,
    VoidCallback tap, {
    int stagger = -1,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final button = GestureDetector(
      onTap: () {
        HapticService.lightImpact();
        tap();
      },
      child: Container(
        width: sz,
        height: sz,
        decoration: isDark
            ? neuBox(radius: sz / 2, borderColor: border)
            : BoxDecoration(
                color: bg,
                shape: BoxShape.circle,
                border: Border.all(color: border),
              ),
        child: Icon(ic, color: iconColor, size: sz * 0.44),
      ),
    );
    // Entrance stagger: side FABs fade+scale in one after another.
    if (stagger >= 0 && _enterFabs.isNotEmpty) {
      final a = _enterFabs[stagger.clamp(0, _enterFabs.length - 1)];
      return FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: a, child: button),
      );
    }
    return button;
  }

  Widget _avatar(double s, {bool showBadge = false}) {
    final circle = VerifiedAvatar(
      photoUrl: _riderPhotoUrl.isNotEmpty ? _riderPhotoUrl : null,
      radius: s / 2,
      fallbackName: _riderName,
      uid: _riderId.isNotEmpty ? _riderId : null,
      role: 'rider',
      isVerified: false,
    );
    if (!showBadge) return circle;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        circle,
        Positioned(
          bottom: -2,
          right: -2,
          child: Container(
            width: s * 0.38,
            height: s * 0.38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _gold,
              border: Border.all(color: const Color(0xFF0A0A0A), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: _gold.withValues(alpha: 0.4),
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Icon(
              Icons.check,
              color: Colors.black,
              size: s * 0.22,
            ),
          ),
        ),
      ],
    );
  }

  Widget _actionBtn(IconData ic, VoidCallback tap) {
    return GestureDetector(
      onTap: () {
        HapticService.lightImpact();
        tap();
      },
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: _gold.withValues(alpha: 0.1),
          shape: BoxShape.circle,
          border: Border.all(color: _gold.withValues(alpha: 0.2)),
        ),
        child: Icon(ic, color: _gold, size: 18),
      ),
    );
  }

  // _cancelRow removed 2026-04-11 — driver cancel policy.

  Widget _sumStat(String v, String l, Color vColor, Color lColor) => Column(
        children: [
          Text(
            v,
            style: TextStyle(
              color: vColor,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(l, style: TextStyle(color: lColor, fontSize: 10)),
        ],
      );
}

/// Data for a single offer-card badge (scheduled / airport / cash).
class _OfferBadgeData {
  const _OfferBadgeData({
    required this.label,
    required this.icon,
    required this.color,
  });
  final String label;
  final IconData icon;
  final Color color;
}

/// Render a compact pill-shaped badge used on the driver offer card.
/// The color controls both the border and the translucent fill.
Widget _buildOfferBadge(_OfferBadgeData b) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: b.color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: b.color.withValues(alpha: 0.4)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(b.icon, size: 14, color: b.color),
        const SizedBox(width: 5),
        Text(
          b.label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
            color: b.color,
          ),
        ),
      ],
    ),
  );
}

/// A self-contained VIP/Comfort/Premium badge with a professional
/// shimmer sweep animation (light streak moves left→right).
/// DEPRECATED as of 2026-04-11: the offer card no longer displays
/// vehicle-type badges. Keeping the class so the route-preview panel
/// (which still uses it) doesn't break, but it's not rendered on the
/// compact offer card anymore.
class _ShimmerBadge extends StatefulWidget {
  const _ShimmerBadge({required this.label});
  final String label;

  @override
  State<_ShimmerBadge> createState() => _ShimmerBadgeState();
}

class _ShimmerBadgeState extends State<_ShimmerBadge>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        // Sweep position across the badge width
        final sweep = -0.3 + (_ctrl.value * 1.6);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1F),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Color.lerp(
                _gold.withValues(alpha: 0.30),
                _gold.withValues(alpha: 0.65),
                _shimmerIntensity(sweep),
              )!,
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: _gold.withValues(
                    alpha: 0.08 + _shimmerIntensity(sweep) * 0.15),
                blurRadius: 8 + _shimmerIntensity(sweep) * 6,
                spreadRadius: _shimmerIntensity(sweep) * 2,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(
              children: [
                // Normal badge content
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.person_rounded, size: 14, color: _gold),
                    const SizedBox(width: 6),
                    Text(
                      widget.label,
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                // Shimmer light streak overlay
                Positioned.fill(
                  child: IgnorePointer(
                    child: ShaderMask(
                      shaderCallback: (bounds) {
                        return LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            Colors.transparent,
                            Colors.white.withValues(alpha: 0.5),
                            Colors.transparent,
                          ],
                          stops: [
                            (sweep - 0.12).clamp(0.0, 1.0),
                            sweep.clamp(0.0, 1.0),
                            (sweep + 0.12).clamp(0.0, 1.0),
                          ],
                        ).createShader(bounds);
                      },
                      blendMode: BlendMode.srcIn,
                      child: Container(color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  double _shimmerIntensity(double sweep) {
    // Returns 0..1 based on how centered the sweep is (peak at 0.5)
    final dist = (sweep - 0.5).abs();
    return (1.0 - dist * 2.0).clamp(0.0, 1.0);
  }
}
