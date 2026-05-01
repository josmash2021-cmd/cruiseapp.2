part of 'driver_online_screen.dart';

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
    return RepaintBoundary(
      child: mapbox.MapWidget(
        key: _mapKey,
        textureView: true,
        styleUri: MapboxConfig.styleDark,
        cameraOptions: mapbox.CameraOptions(
          center: mapbox.Point(coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),
          zoom: 15.5,
          bearing: 0,
          pitch: 0,
        ),
        onMapCreated: (ctrl) {
          _map = ctrl;
          _lastStyleDark = isDark;
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
          _goldDotAnnot = null;
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
          Future.microtask(() async {
            // Polyline manager with no 'below' constraint — avoids silent failure
            // when the layer name doesn't exist in the style.
            _polylineAnnotMgr = await ctrl.annotations.createPolylineAnnotationManager(
              below: "road-label",
            );
            _pointAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
            try { await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-pitch-alignment', 'viewport'); } catch (_) {}
            try { await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-allow-overlap', true); } catch (_) {}
            try { await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-ignore-placement', true); } catch (_) {}
            // Separate pin manager for teardrop pins — anchored at tip (bottom), upright (viewport)
            _pinAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
            try { await ctrl.style.setStyleLayerProperty(_pinAnnotMgr!.id, 'icon-pitch-alignment', 'viewport'); } catch (_) {}
            try { await ctrl.style.setStyleLayerProperty(_pinAnnotMgr!.id, 'icon-rotation-alignment', 'viewport'); } catch (_) {}
            try { await ctrl.style.setStyleLayerProperty(_pinAnnotMgr!.id, 'icon-allow-overlap', true); } catch (_) {}
            try { await ctrl.style.setStyleLayerProperty(_pinAnnotMgr!.id, 'icon-ignore-placement', true); } catch (_) {}
            try { await ctrl.style.setStyleLayerProperty(_pinAnnotMgr!.id, 'icon-anchor', 'bottom'); } catch (_) {}
            // Use already-known position from home screen — no blocking GPS call needed
            if (_pos != null) _animateToPosition(_pos!, zoom: 15.5, bearing: _heading, tilt: 0);
            _updateDriverAnnotation();
            // Re-draw route if map initialised after _drawRoute already ran
            if (_routePts.length > 1) {
              _setRouteAnnotation(_routePts, _navyRoute);
              final dest = (_phase == _Phase.enRouteToPickup || _phase == _Phase.routeSummary)
                  ? _pickupLL
                  : _dropoffLL;
              if (_pos != null) _fitBounds(_pos!, dest);
            }
          });
        },
        onStyleLoadedListener: (_) async {
          if (_map != null) {
            await MapTheme.applyNavyGold(_map!);
            // Ensure top-down view on entry (no tilt unless actively navigating)
            if (_phase == _Phase.searching || _phase == _Phase.rideRequest) {
              await _map!.flyTo(
                mapbox.CameraOptions(pitch: 0, bearing: 0),
                mapbox.MapAnimationOptions(duration: 0),
              );
            }
            // Re-apply pin layer properties after style reload —
            // applyNavyGold resets them so they must be re-set here.
            if (_pinAnnotMgr != null) {
              try { await _map!.style.setStyleLayerProperty(_pinAnnotMgr!.id, 'icon-rotation-alignment', 'viewport'); } catch (_) {}
              try { await _map!.style.setStyleLayerProperty(_pinAnnotMgr!.id, 'icon-pitch-alignment', 'viewport'); } catch (_) {}
              try { await _map!.style.setStyleLayerProperty(_pinAnnotMgr!.id, 'icon-anchor', 'bottom'); } catch (_) {}
              try { await _map!.style.setStyleLayerProperty(_pinAnnotMgr!.id, 'icon-allow-overlap', true); } catch (_) {}
            }
            if (_pointAnnotMgr != null) {
              try { await _map!.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-pitch-alignment', 'viewport'); } catch (_) {}
              try { await _map!.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-allow-overlap', true); } catch (_) {}
            }
          }
        },
        onScrollListener: (_) {
          _onCameraMoveStarted();
        },
      ),
    );
  }


  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  EARNINGS PILL (top center — Uber style)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _earningsPill(bool isDark) {
    final pillBg = isDark
        ? Colors.black
        : Colors.white.withValues(alpha: 0.9);
    final pillBorder = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);
    final pillText = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final pillSub = isDark ? Colors.white38 : Colors.black38;
    final dotActive = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final dotInactive = isDark
        ? Colors.white.withValues(alpha: 0.2)
        : Colors.black.withValues(alpha: 0.15);

    final amounts = [
      _weeklyEarnings,
      _earnings,
      _lastTripEarnings,
    ];
    final prevAmounts = [
      _prevWeeklyEarnings,
      _prevEarnings,
      _prevLastTripEarnings,
    ];
    final labels = [
      S.of(context).thisWeek.toUpperCase(),
      S.of(context).today.toUpperCase(),
      S.of(context).lastTripLabel.toUpperCase(),
    ];

    Widget pillPage(double amount, double prevAmount, String label) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
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
                  builder: (_, val, __) => Text(
                    '\$${val.toStringAsFixed(2)}',
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
                    for (int i = 0; i < 3; i++) ...[
                      Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i == _earningsPage ? dotActive : dotInactive,
                        ),
                      ),
                      if (i < 2) const SizedBox(width: 3),
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
        if (details.primaryVelocity! < -200 && _earningsPage < 2) {
          _setState(() => _earningsPage++);
        } else if (details.primaryVelocity! > 200 && _earningsPage > 0) {
          _setState(() => _earningsPage--);
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
            key: ValueKey<int>(_earningsPage),
            child: pillPage(
              amounts[_earningsPage],
              prevAmounts[_earningsPage],
              labels[_earningsPage],
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
      case _Phase.enRouteToPickup:
        return _pickupPanel(
          isDark,
          bg,
          textPrimary,
          textMuted,
          borderC,
          shadowC,
        );
      case _Phase.arrivedAtPickup:
        return _arrivedPanel(
          isDark,
          bg,
          textPrimary,
          textMuted,
          borderC,
          shadowC,
        );
      case _Phase.routeSummary:
        return _routeSummaryPanel(
          isDark,
          bg,
          textPrimary,
          textMuted,
          borderC,
          shadowC,
        );
      case _Phase.inTrip:
        return _tripPanel(isDark, bg, textPrimary, textMuted, borderC, shadowC);
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
    return GestureDetector(
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
            expansion: 1.0,
          ),
          child: Container(
            decoration: BoxDecoration(
              // Pure black bg (no particles per 2026-04-27 spec —
              // particles only on Searching + Waiting screens). The
              // animated gold border above is the searching pulse.
              color: Colors.black,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
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
                    const SizedBox(width: 16),
                    VerifiedAvatar(
                      photoUrl: widget.photoUrl,
                      radius: 15,
                      fallbackName: null,
                      uid: _driverId?.toString(),
                      role: 'driver',
                      isVerified: false,
                    ),
                    const Spacer(),
                    // Connection status dot: green = SSE real-time, amber = polling fallback
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _sseActive ? const Color(0xFF4CAF50) : const Color(0xFFFFA000),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: (_sseActive ? const Color(0xFF4CAF50) : const Color(0xFFFFA000)).withValues(alpha: 0.4),
                            blurRadius: 6,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      S.of(context).findingTrips,
                      style: TextStyle(
                        color: textMuted,
                        fontSize: 15,
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
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
        ),
      ),
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
    final bot = MediaQuery.of(context).padding.bottom;
    // â”€â”€ Always use dark styling for offer cards â”€â”€
    const cCardBg = Color(0xFF1A1A1F);
    final cCardBorder = _gold.withValues(alpha: 0.12);
    final cRejectBg = Colors.red.withValues(alpha: 0.08);
    const cRejectText = Color(0xFFFF6B6B);
    const cTextPrimary = Colors.white;
    final cTextMuted = Colors.white.withValues(alpha: 0.5);
    final cBorderC = Colors.white.withValues(alpha: 0.06);
    final acceptBg = _gold;

    final safeIdx = _currentOfferIndex.clamp(0, (_pendingOffers.length - 1).clamp(0, 999));
    final currentOid = _pendingOffers.isNotEmpty
        ? (_pendingOffers[safeIdx]['offer_id'] ?? _pendingOffers[safeIdx]['id'] ?? '').toString()
        : '';
    final isCardExpanded = _expandedOfferIds.contains(currentOid);

    return Column(
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
                  HapticFeedback.selectionClick();
                  // Only trigger preview if not already animating
                  if (index < _pendingOffers.length && !_isCardAnimating) {
                    _autoTriggerRoutePreview(_pendingOffers[index]);
                  }
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
                          opacity: (1.0 - _rejectSlideCtrl!.value).clamp(0.0, 1.0),
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
                    onTap: () {
                      _pulseCtrl?.reverse();
                      _onOfferCardTap(offer);
                    },
                    onTapCancel: () {
                      _pulseCtrl?.reverse();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
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
                        color: active ? _gold : Colors.white.withValues(alpha: 0.25),
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
                      onVerticalDragUpdate: _hideFindingBar ? null : (details) {
                        if (details.delta.dy < -5) {
                          _showGoOfflineSheet();
                        }
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1A1F),
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
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(top: BorderSide(color: _gold.withValues(alpha: 0.08))),
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
              _panelItem(
                Icons.star_outline_rounded,
                S.of(context).seeUpcomingPromotions,
                panelItemIcon,
                panelItemText,
                panelItemChevron,
                () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    slideFromRightRoute(const DriverPromosScreen()),
                  );
                },
              ),
              _panelItem(
                Icons.access_time_rounded,
                S.of(context).seeDrivingTime,
                panelItemIcon,
                panelItemText,
                panelItemChevron,
                () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    slideFromRightRoute(const DriverAnalyticsScreen()),
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
                            color: const Color(0xFFFFA500).withValues(alpha: 0.15),
                            border: Border.all(
                              color: const Color(0xFFFFA500).withValues(alpha: 0.3),
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
      s = 0; r = 0;
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
    final pickupPin  = 'pin-s+00c853($pLng,$pLat)';
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
      final coords = sampled.map((p) => '${p[0].toStringAsFixed(5)},${p[1].toStringAsFixed(5)}').join(';');
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
    Color borderC,
  ) {
    const luxGold = Color(0xFFD4AF37);
    const deepBlack = Color(0xFF0F0F0F);
    const mutedGray = Color(0xFF9A9A9A);

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
    final vehicleType = _mapRideType((offer['vehicle_type'] ?? 'Comfort') as String);
    final pickupLL = LatLng(pickupLat, pickupLng);
    final dropoffLL = LatLng(dropoffLat, dropoffLng);
    final pickupAddr = _isGenericAddress(rawPickupAddr)
        ? (_resolvedAddressCache['${pickupLat}_$pickupLng'] ?? rawPickupAddr)
        : rawPickupAddr;

    // Cache per offer so we don't re-fetch on every rebuild
    final offerId = (offer['offer_id'] ?? offer['id'] ?? '${pickupLat}_$pickupLng').toString();

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

    if (_pos != null && pickupLat != 0 && pickupLng != 0 && dropoffLat != 0 && dropoffLng != 0) {
      _offerMapUrlCache.putIfAbsent(
        offerId,
        () => _buildOfferMapUrl(_pos!, pickupLL, dropoffLL),
      );
    }

    final isExpanded = _expandedOfferIds.contains(offerId);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: deepBlack,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFE8C547).withValues(alpha: 0.25),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 24,
            spreadRadius: 2,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.20),
            blurRadius: 48,
            spreadRadius: 0,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(12, isExpanded ? 8 : 6, 12, isExpanded ? 8 : 6),
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
                        ),
            ),
          ),
          // X Reject button — top-right corner of the card
          Positioned(
            right: 6,
            top: 6,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticFeedback.lightImpact();
                _rejectOffer(offer);
              },
              child: Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1F),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFE53935).withValues(alpha: 0.4),
                      width: 1,
                    ),
                  ),
                  child: const Icon(Icons.close, color: Color(0xFFE53935), size: 14),
                ),
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
    final bool isCashRide =
        paymentMethod == 'cash' || offer['is_cash'] == true;

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

    return Column(
      key: const ValueKey('compact'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // ── Badges (scheduled / airport / cash) ─────────────────────
        if (badges.isNotEmpty) ...[
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final b in badges) _buildOfferBadge(b),
            ],
          ),
          const SizedBox(height: 4),
          if (isScheduled) ...[
            // Scheduled time display — only when VIAJE RESERVADO is on.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
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

        // ── ROW 2: Price + Tips (centered) ──
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '\$${fare.toStringAsFixed(2)}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 32,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '+ Tips',
              style: const TextStyle(
                color: goldAccent,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        // ── Rating + Total trip time & distance (centered, gold metrics) ──
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (riderIsNew)
              Text(
                S.of(context).newRiderLabel,
                style: TextStyle(
                  color: goldAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              )
            else if (hasRating) ...[
              Icon(Icons.star_rounded, color: goldAccent, size: 13),
              const SizedBox(width: 3),
              Text(
                rating.toStringAsFixed(1),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (riderIsNew || hasRating) const SizedBox(width: 12),
            Icon(Icons.access_time_rounded, color: goldAccent, size: 12),
            const SizedBox(width: 3),
            Text(
              '${etaToPickup + tripEta} min',
              style: const TextStyle(
                color: goldAccent,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 10),
            Icon(Icons.straighten_rounded, color: goldAccent, size: 12),
            const SizedBox(width: 3),
            Text(
              '${(distToPickupMi + tripDistMi).toStringAsFixed(1)} mi',
              style: const TextStyle(
                color: goldAccent,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),

        const SizedBox(height: 8),

        // ── ROW 3: Route indicator (gold ● line ■ with addresses + inline metrics) ──
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1F),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Gold ● | ■ indicator column
              Padding(
                padding: const EdgeInsets.only(top: 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Gold filled circle (pickup)
                    Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: Color(0xFFD4A843),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Gold vertical line
                    Container(
                      width: 2,
                      height: 28,
                      color: const Color(0xFFD4A843).withValues(alpha: 0.4),
                    ),
                    const SizedBox(height: 4),
                    // Black square with gold shadow (dropoff)
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(2),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x55D4A843),
                            blurRadius: 6,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // Address details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Pickup info
                    Text(
                      '$etaToPickup min (${distToPickupMi.toStringAsFixed(1)} mi) away',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      pickupAddr,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 10),
                    // Dropoff info
                    Text(
                      '$tripEta min (${tripDistMi.toStringAsFixed(1)} mi) trip',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      dropoffAddr,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 6),

        // ── Divider ──
        Container(
          height: 0.5,
          color: const Color(0xFF333333),
        ),

        const SizedBox(height: 4),

        // ── ROW 5: Accept button — GOLD — ALWAYS VISIBLE ──
        GestureDetector(
          onTapDown: (_) => _setState(() => _isAcceptPressed = true),
          onTapUp: (_) {
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
                color: const Color(0xFFD4A843),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(
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
        ),
      ],
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
    final botPad = MediaQuery.of(context).padding.bottom;
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
    // Base 253 = old 275 minus 22 for the removed _ShimmerBadge row.
    return 253 + extra + (botPad > 20 ? botPad - 10 : 0);
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
      return s.schedTimeInHours(
          timeStr, diff.inHours, diff.inMinutes % 60);
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
    final name = (offer['rider_name'] as String?) ?? S.of(context).riderFallback;
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
    final vehicleType = _mapRideType((offer['vehicle_type'] ?? 'Comfort') as String);
    final pickupAddr = _isGenericAddress(rawPickupAddr2)
        ? (_resolvedAddressCache['${pickupLat}_$pickupLng'] ?? rawPickupAddr2)
        : rawPickupAddr2;
    final previewOfferId = (offer['offer_id'] ?? offer['id'] ?? '${pickupLat}_$pickupLng').toString();
    final cachedPreview = _routeCache[previewOfferId];
    final int etaToPickup;
    final int tripEta;
    final double distToPickupMi;
    final double tripDistMi;
    if (cachedPreview?.driverToPickupKm != null && cachedPreview?.pickupToDropoffKm != null) {
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
                                  color: _gold, fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              )
                            else if (hasRating)
                              Row(
                                children: [
                                  const Icon(Icons.star_rounded, color: _gold, size: 13),
                                  const SizedBox(width: 3),
                                  Text(
                                    rating.toStringAsFixed(1),
                                    style: const TextStyle(
                                      color: _gold, fontSize: 12,
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

  // â”€â”€ ROUTE SUMMARY PANEL (Google Maps-style overview before navigation) â”€â”€
  Widget _routeSummaryPanel(
    bool isDark,
    Color bg,
    Color textPrimary,
    Color textMuted,
    Color borderC,
    Color shadowC,
  ) {
    return _wrapInDraggableSheet(
      isDark: isDark,
      surface: bg,
      shadowC: shadowC,
      minChildSize: 0.45,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _handle(isDark),
          const SizedBox(height: 10),
          // Rider info header with fare
          Row(
            children: [
              _avatar(42, showBadge: true),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _riderName,
                      style: TextStyle(
                        color: textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      _vehicleType,
                      style: TextStyle(
                        color: _gold,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '\$${_fare.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: _gold,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Distance / ETA / Trip info badges
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _summaryBadge(
                Icons.navigation_rounded,
                '${(_navDist * 0.621371).toStringAsFixed(1)} mi',
                textPrimary,
                textMuted,
              ),
              _summaryBadge(
                Icons.access_time_rounded,
                '$_navEta min',
                textPrimary,
                textMuted,
              ),
              _summaryBadge(
                Icons.route_rounded,
                '${(_tripDist * 0.621371).toStringAsFixed(1)} mi trip',
                textPrimary,
                textMuted,
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Pickup & Dropoff addresses
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _gold.withValues(alpha: 0.10)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.location_on_rounded, color: _gold, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _pickupAddr,
                        style: TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                        maxLines: 3,
                        softWrap: true,
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 2, height: 16,
                      color: _gold.withValues(alpha: 0.3),
                    ),
                  ),
                ),
                Row(
                  children: [
                    const Icon(Icons.flag_rounded, color: _gold, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _dropoffAddr,
                        style: TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                        maxLines: 3,
                        softWrap: true,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // Re-center button + Start Navigation button
          Row(
            children: [
              // Re-center / overview button
              GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  _fitBoundsMulti([_pos!, _pickupLL, _dropoffLL]);
                },
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _gold.withValues(alpha: 0.2)),
                  ),
                  child: const Icon(
                    Icons.center_focus_strong_rounded,
                    color: _gold,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Start Navigation button
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: () => _beginNavigation(),
                    icon: const Icon(
                      Icons.navigation_rounded,
                      color: Colors.black,
                      size: 20,
                    ),
                    label: Flexible(
                      child: Text(
                        S.of(context).startNavigation,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      elevation: 4,
                      shadowColor: _gold.withValues(alpha: 0.3),
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
    );
  }

  // ── PICKUP PANEL ──
  Widget _pickupPanel(
    bool isDark,
    Color bg,
    Color textPrimary,
    Color textMuted,
    Color borderC,
    Color shadowC,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 14,
            offset: const Offset(0, -4),
          )
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: borderC,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  const Icon(Icons.location_on_rounded, color: _gold, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _riderName,
                          style: TextStyle(
                            color: textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _pickupAddr,
                          style: TextStyle(
                            color: textMuted,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 3,
                          softWrap: true,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () async {
                      if (_riderPhone.isNotEmpty) {
                        final uri = Uri(scheme: 'tel', path: _riderPhone);
                        if (await canLaunchUrl(uri)) await launchUrl(uri);
                      }
                    },
                    icon: const Icon(Icons.phone, color: _gold, size: 22),
                    style: IconButton.styleFrom(
                      backgroundColor: isDark
                          ? Colors.white.withValues(alpha: 0.1)
                          : Colors.black.withValues(alpha: 0.05),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Navigate button row
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => MapLauncherService.navigate(
                        destLat: _pickupLL.latitude,
                        destLng: _pickupLL.longitude,
                      ),
                      icon: const Icon(Icons.navigation_rounded, size: 18),
                      label: Text(S.of(context).navigateLabel),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: isDark ? Colors.white : Colors.black,
                        side: BorderSide(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.2)
                              : Colors.black.withValues(alpha: 0.2),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        minimumSize: const Size.fromHeight(48),
                        textStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _arrivePickup,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    _nearPickupNotified
                        ? S.of(context).arrived.toUpperCase()
                        : S.of(context).arrivedAtPickup.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
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

  // ── ARRIVED PANEL ──
  Widget _arrivedPanel(
    bool isDark,
    Color bg,
    Color textPrimary,
    Color textMuted,
    Color borderC,
    Color shadowC,
  ) {
    return _wrapInDraggableSheet(
      isDark: isDark,
      surface: bg,
      shadowC: shadowC,
      minChildSize: 0.38,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _handle(isDark),
          const SizedBox(height: 12),
          // Waiting status
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: _goldLight.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _goldLight.withValues(alpha: 0.1)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(
                      _goldLight.withValues(alpha: 0.8),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  S.of(context).waitingForRider,
                  style: TextStyle(
                    color: textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _avatar(50, showBadge: true),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _riderName,
                      style: TextStyle(
                        color: textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _gold.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _vehicleType,
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _actionBtn(Icons.phone_rounded, () async {
                if (_riderPhone.isNotEmpty) {
                  final uri = Uri(scheme: 'tel', path: _riderPhone);
                  if (await canLaunchUrl(uri)) await launchUrl(uri);
                }
              }),
              const SizedBox(width: 8),
              Stack(
                clipBehavior: Clip.none,
                children: [
                  _actionBtn(Icons.chat_bubble_rounded, () {
                    Navigator.of(context).push(
                      slideFromRightRoute(ChatScreen(
                        recipientName: _riderName,
                        recipientPhone: _riderPhone,
                        tripId: _tripId,
                        currentUserId: _driverId?.toString(),
                        currentRole: 'driver',
                      )),
                    );
                  }),
                  if (_tripId != null)
                    StreamBuilder<int>(
                      stream: ChatService().unreadCountStream(
                        rideId: _tripId.toString(),
                        readerRole: 'driver',
                      ),
                      builder: (context, snap) {
                        final count = snap.data ?? 0;
                        if (count == 0) return const SizedBox.shrink();
                        return Positioned(
                          right: -4,
                          top: -4,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: Color(0xFFEF4444),
                              shape: BoxShape.circle,
                            ),
                            constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                            child: Text(
                              count > 9 ? '9+' : '$count',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          // START TRIP button
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _startTrip,
              icon: const Icon(
                Icons.play_arrow_rounded,
                color: Colors.black,
                size: 22,
              ),
              label: Text(
                S.of(context).startTrip,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                elevation: 4,
                shadowColor: _gold.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          // Cancel policy 2026-04-11: driver can no longer directly
          // cancel. The old _cancelRow textbutton was removed — any
          // driver-initiated abort must go through "Contact Support".
        ],
      ),
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

  Widget _tripPanel(
    bool isDark,
    Color bg,
    Color textPrimary,
    Color textMuted,
    Color borderC,
    Color shadowC,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 16,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ETA strip - Uber style
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$_navEta min',
                        style: TextStyle(
                          color: textPrimary,
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          height: 1.0,
                        ),
                      ),
                      Text(
                        '${(_navDist * 0.621371).toStringAsFixed(1)} mi away',
                        style: TextStyle(
                          color: textMuted,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '\$${_fare.toStringAsFixed(2)}',
                    style: TextStyle(
                      color: textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Rider info with avatar + badge
              Row(
                children: [
                  _avatar(42, showBadge: true),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _riderName,
                          style: TextStyle(
                            color: textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _vehicleType,
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () async {
                      if (_riderPhone.isNotEmpty) {
                        final uri = Uri(scheme: 'tel', path: _riderPhone);
                        if (await canLaunchUrl(uri)) await launchUrl(uri);
                      }
                    },
                    icon: const Icon(
                      Icons.phone,
                      color: _gold,
                      size: 22,
                    ),
                    style: IconButton.styleFrom(
                      backgroundColor: isDark
                          ? Colors.white.withValues(alpha: 0.1)
                          : Colors.black.withValues(alpha: 0.05),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Dropoff address card — full text, gold icon
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1A1A1F) : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.flag_rounded, color: _gold, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _dropoffAddr,
                        style: TextStyle(
                          color: textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 3,
                        softWrap: true,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // Navigate to dropoff button
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => MapLauncherService.navigate(
                        destLat: _dropoffLL.latitude,
                        destLng: _dropoffLL.longitude,
                      ),
                      icon: const Icon(Icons.navigation_rounded, size: 18),
                      label: Text(S.of(context).navigateLabel),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: isDark ? Colors.white : Colors.black,
                        side: BorderSide(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.2)
                              : Colors.black.withValues(alpha: 0.2),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        minimumSize: const Size.fromHeight(48),
                        textStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // COMPLETE TRIP button - Uber style
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _complete,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _nearDropoffNotified
                        ? Colors.black
                        : Colors.black.withValues(alpha: 0.3),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    _nearDropoffNotified
                        ? S.of(context).finishTrip.toUpperCase()
                        : 'COMPLETE TRIP',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
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
                                HapticFeedback.selectionClick();
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
      _setState(() => _panelOpen = target > 0.5);
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

    // Collapsed pill height + expanded max height
    const collapsedH = 78.0;
    final expandedH = screenH * 0.55;
    final currentH = collapsedH + (expandedH - collapsedH) * t;

    // Margins: collapsed = 12 horizontal + 10 bottom; expanded = 0
    final hMargin = 12.0 * (1.0 - t);
    final bMargin = (10.0 + botPad) * (1.0 - t);

    // Border radius: collapsed = 20 all; expanded = 24 top only
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(24),
      topRight: const Radius.circular(24),
      bottomLeft: Radius.circular(20.0 * (1.0 - t)),
      bottomRight: Radius.circular(20.0 * (1.0 - t)),
    );

    final panelItemText = isDark
        ? Colors.white.withValues(alpha: 0.7)
        : Colors.black.withValues(alpha: 0.6);
    final panelItemIcon = isDark
        ? Colors.white.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.4);
    final panelItemChevron = isDark
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.black.withValues(alpha: 0.12);

    return Positioned(
      bottom: bMargin,
      left: hMargin,
      right: hMargin,
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
              expansion: t,
            ),
            child: child,
          ),
          child: Container(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: radius,
            boxShadow: [
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
                t > 0.5 ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_up_rounded,
                color: textMuted.withValues(alpha: 0.5),
                size: 16,
              ),
              // Header row
              SizedBox(
                height: 28,
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    Icon(Icons.tune_rounded, color: textMuted, size: 20),
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
                      size: 20,
                    ),
                    const SizedBox(width: 16),
                  ],
                ),
              ),
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
                        const SizedBox(height: 12),
                        Divider(height: 1, color: borderC),
                        const SizedBox(height: 16),
                        Center(
                          child: Text(
                            S.of(context).recommendedForYou,
                            style: TextStyle(
                              color: textPrimary,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
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
                            Navigator.push(
                              context,
                              slideFromRightRoute(const DriverEarningsScreen()),
                            );
                          },
                        ),
                        _panelItem(
                          Icons.star_outline_rounded,
                          S.of(context).seeUpcomingPromotions,
                          panelItemIcon,
                          panelItemText,
                          panelItemChevron,
                          () {
                            Navigator.push(
                              context,
                              slideFromRightRoute(const DriverPromosScreen()),
                            );
                          },
                        ),
                        _panelItem(
                          Icons.access_time_rounded,
                          S.of(context).seeDrivingTime,
                          panelItemIcon,
                          panelItemText,
                          panelItemChevron,
                          () {
                            Navigator.push(
                              context,
                              slideFromRightRoute(const DriverAnalyticsScreen()),
                            );
                          },
                        ),
                        const SizedBox(height: 20),
                        // GO OFFLINE button
                        Center(
                          child: GestureDetector(
                            onTap: _goOffline,
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
                        ),
                        const SizedBox(height: 20),
                        SizedBox(height: botPad),
                      ],
                    ),
                  ),
                )
              else
                const Spacer(),
            ],
          ),
        ),
        ),
      ),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        onTap: () {
          HapticFeedback.selectionClick();
          tap();
        },
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        leading: Icon(ic, color: iconC, size: 22),
        title: Text(
          txt,
          style: TextStyle(
            color: textC,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        trailing: Icon(Icons.chevron_right_rounded, color: chevronC, size: 20),
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
                          HapticFeedback.heavyImpact();
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
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
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
    VoidCallback tap,
  ) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        tap();
      },
      child: Container(
        width: sz,
        height: sz,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          border: Border.all(color: border),
        ),
        child: Icon(ic, color: iconColor, size: sz * 0.44),
      ),
    );
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
        HapticFeedback.lightImpact();
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
                color: _gold.withValues(alpha: 0.08 + _shimmerIntensity(sweep) * 0.15),
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
