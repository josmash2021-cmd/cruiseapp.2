part of 'home_screen.dart';

// ════════════════════════════════════════════════════════════
//  WIDGETS — UI builders, panels, cards
// ════════════════════════════════════════════════════════════

extension _HomeScreenWidgets on _HomeScreenState {

  // ════════════════════════════════════════════════════
  //  M A P - F I R S T   H E L P E R S
  // ════════════════════════════════════════════════════

  // Full-screen Mapbox background
  Widget _buildFullMap() {
    if (_currentLatLng == null) {
      return Container(
        color: const Color(0xFF07080D),
        child: const Center(
          child: CircularProgressIndicator(color: _gold, strokeWidth: 2),
        ),
      );
    }
    final pos = _currentLatLng!;
    return mapbox.MapWidget(
      key: _mapKey,
      styleUri: MapboxConfig.styleDark,
      cameraOptions: mapbox.CameraOptions(
        center: mapbox.Point(
          coordinates: mapbox.Position(pos.longitude, pos.latitude),
        ),
        zoom: 15.0,
      ),
      onMapCreated: (ctrl) async {
        _miniMapController = ctrl;
        ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
        ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
        ctrl.attribution
            .updateSettings(mapbox.AttributionSettings(enabled: false));
        ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));
        _miniMapAnnotMgr =
            await ctrl.annotations.createPointAnnotationManager();
        try {
          await ctrl.style.setStyleLayerProperty(_miniMapAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
          await ctrl.style.setStyleLayerProperty(_miniMapAnnotMgr!.id, 'icon-rotation-alignment', 'viewport');
          await ctrl.style.setStyleLayerProperty(_miniMapAnnotMgr!.id, 'icon-allow-overlap', true);
        } catch (_) {}
        // LocationPuck disabled — GoldLocationDot annotation handles location display
        // Draw route if there's an active ride
        if (_activeRide != null) {
          _drawRouteOnMap();
        }
      },
      onStyleLoadedListener: (_) async {
        if (_miniMapController != null) {
          await _applyDarkNavyGoldTheme(_miniMapController!);
          // Re-apply annotation manager layer properties after style reload
          if (_miniMapAnnotMgr != null) {
            try {
              await _miniMapController!.style.setStyleLayerProperty(_miniMapAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
              await _miniMapController!.style.setStyleLayerProperty(_miniMapAnnotMgr!.id, 'icon-rotation-alignment', 'viewport');
              await _miniMapController!.style.setStyleLayerProperty(_miniMapAnnotMgr!.id, 'icon-allow-overlap', true);
            } catch (_) {}
          }
        }
      },
    );
  }

  Future<Uint8List> _buildGoldPuckImage() async {
    const size = 24.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(size / 2, size / 2);
    canvas.drawCircle(center, size / 2, Paint()..color = Colors.white);
    canvas.drawCircle(center, size / 2 - 3, Paint()..color = const Color(0xFFE8C547));
    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  // "Where to?" / "Ride in progress" search bar floating over the map
  Widget _buildWhereToBar() {
    final active = _activeRide != null;
    final searching = _pendingSearchTripId != null && !active;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOutCubic,
      height: Responsive.h(48),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: active
              ? _gold.withValues(alpha: 0.35)
              : searching
                  ? Colors.blue.withValues(alpha: 0.4)
                  : Colors.white.withValues(alpha: 0.08),
          width: (active || searching) ? 1.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: active
                ? _gold.withValues(alpha: 0.10)
                : searching
                    ? Colors.blue.withValues(alpha: 0.10)
                    : Colors.black.withValues(alpha: 0.5),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 400),
        switchInCurve: Curves.easeInOutCubic,
        switchOutCurve: Curves.easeInOutCubic,
        transitionBuilder: (child, anim) =>
            FadeTransition(opacity: anim, child: child),
        child: active
            ? _buildRideActiveContent()
            : searching
                ? _buildSearchingDriverContent()
                : _buildWhereToContent(),
      ),
    );
  }

  // "Buscando conductor..." content — shown when trip is searching on reopen
  Widget _buildSearchingDriverContent() {
    return GestureDetector(
      key: const ValueKey('searching_driver'),
      onTap: () {},
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          const SizedBox(width: 14),
          const SizedBox(
            width: 18, height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              S.of(context).searchingForDriver,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: Responsive.sp(14),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          GestureDetector(
            onTap: () async {
              final tripId = _pendingSearchTripId;
              if (tripId == null) return;
              bool backendOk = false;
              try {
                await ApiService.cancelTrip(tripId);
                backendOk = true;
              } catch (e) {
                debugPrint('[HomeScreen] cancelTrip($tripId) failed: $e');
              }
              _pendingSearchTimer?.cancel();
              if (!mounted) return;
              _setState(() => _pendingSearchTripId = null);
              if (!backendOk) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(S.of(context).cancelTripCheckConnection),
                    backgroundColor: Colors.red.shade700,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                S.of(context).cancel,
                style: const TextStyle(
                  color: Colors.red, fontSize: 12, fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Normal "Where to?" search bar content
  Widget _buildWhereToContent() {
    final locked = !_isVerified;
    return GestureDetector(
      key: const ValueKey('where_to'),
      onTap: locked ? _showVerificationBlockedDialog : _openSearchThenRide,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          SizedBox(width: Responsive.w(16)),
          Icon(
            locked ? Icons.lock_rounded : Icons.search_rounded,
            color: locked
                ? Colors.white.withValues(alpha: 0.3)
                : Colors.white.withValues(alpha: 0.5),
            size: Responsive.sp(20),
          ),
          SizedBox(width: Responsive.w(10)),
          Expanded(
            child: Text(
              S.of(context).whereTo,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: Responsive.sp(16),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          SizedBox(width: Responsive.w(12)),
        ],
      ),
    );
  }

  // "Ride in progress" content — same card, gold accent
  Widget _buildRideActiveContent() {
    return GestureDetector(
      key: const ValueKey('ride_active'),
      onTap: _resumeActiveRide,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          const SizedBox(width: 10),
          // Car icon inside gold circle
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: _gold, width: 1.5),
            ),
            child: Center(
              child: Icon(Icons.directions_car_rounded, color: _gold, size: 16),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              S.of(context).rideInProgress,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Icon(Icons.arrow_forward_ios_rounded,
                color: _gold, size: 14),
          ),
        ],
      ),
    );
  }

  // Floating FAB buttons on top of map (notifications only)
  Widget _buildMapFab() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _glassIconButton(
          Icons.notifications_rounded,
          badge: _unreadNotifications > 0 ? _unreadNotifications : 0,
          onTap: _openNotificationsSheet,
        ),
      ],
    );
  }

  // Small avatar pill for the FAB area
  Widget _buildAvatarChip() {
    return VerifiedAvatar(
      photoUrl: _photoUrl ?? UserSession.photoUrlNotifier.value,
      photoPath: _photoPath,
      radius: 22,
      fallbackName: '$_firstName $_lastName',
      uid: UserSession.currentUid,
      role: 'rider',
      isVerified: _isVerified,
    );
  }

  // Draggable bottom sheet content
  Widget _buildSheet(ScrollController sc, double botPad) {
    final screenW = MediaQuery.of(context).size.width;
    final topPad = MediaQuery.of(context).padding.top;

    return AnimatedBuilder(
      animation: _sheetController,
      builder: (context, child) {
        double size = _kMinSheet;
        try { size = _sheetController.size; } catch (_) {}
        final frac = ((size - 0.85) / (_kMaxSheet - 0.85)).clamp(0.0, 1.0);
        final r = 28.0 * (1.0 - frac);
        final topExtra = frac * topPad;

        // ── Collapsed → expanded crossfade ───────────────────────
        // collapseT = 1.0 when fully collapsed (mini bar), 0.0 when
        // anywhere above the lower 30% of the drag range.
        // Curve is sharp on purpose so the full sheet feels "snapped
        // into view" rather than a slow muddy fade.
        final dragRange = (_kMaxSheet - _kMinSheet);
        final raw = ((size - _kMinSheet) / dragRange).clamp(0.0, 1.0);
        final expandT = Curves.easeOutCubic.transform(
          (raw / 0.18).clamp(0.0, 1.0),
        );
        final collapseT = 1.0 - expandT;
        // Drive the collapsed glow only while the bar is visible —
        // saves frames when fully expanded.
        if (collapseT > 0.05 && !_collapsedGlowCtrl.isAnimating) {
          _collapsedGlowCtrl.repeat();
        } else if (collapseT <= 0.05 && _collapsedGlowCtrl.isAnimating) {
          _collapsedGlowCtrl.stop();
        }

        return DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.vertical(top: Radius.circular(r)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.65),
                blurRadius: 32,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: Stack(
            children: [
              // ── Animated gold border on the mini bar ───────────
              // Painted as a Stack peer so it only ever covers the
              // mini-bar region and never bleeds into the expanded
              // content above.
              if (collapseT > 0.05)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: MediaQuery.of(context).size.height * _kMinSheet,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: collapseT,
                      child: AnimatedBuilder(
                        animation: _collapsedGlowCtrl,
                        builder: (_, __) => CustomPaint(
                          foregroundPainter: SearchingBorderPainter(
                            progress: _collapsedGlowCtrl.value,
                            expansion: 1.0,
                            cornerRadius: 28.0,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

              ClipRRect(
            borderRadius: BorderRadius.vertical(top: Radius.circular(r)),
            // Gold-particle field behind the sheet's scroll content.
            // Opacity tied to expandT so the particles fade in as the
            // sheet expands and stay invisible behind the collapsed
            // mini-bar (where the animated gold border owns the look).
            child: Stack(children: [
              if (expandT > 0.05)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: expandT * 0.9,
                      child: const GoldParticlesBackground(
                        particleCount: 28,
                        child: SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
            CustomScrollView(
              controller: sc,
              physics: _activeRide != null
                  ? const NeverScrollableScrollPhysics()
                  : const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
              slivers: [
                SliverToBoxAdapter(child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Top safe-area spacer when fully expanded ──
                  SizedBox(height: topExtra),
                  // ── Drag handle ──
                  const SizedBox(height: 10),
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

              // ── Greeting row (always visible in collapsed state) ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: RepaintBoundary(child: _buildTopBar()),
              ),
              SizedBox(height: 24 * expandT),

              // ── Everything below the topbar fades in/out with the
              // collapsed → expanded transition. While collapsed the
              // content has 0 opacity AND ignores hits so the user
              // can't accidentally tap the hidden Where-to? card.
              Opacity(
                opacity: expandT,
                child: IgnorePointer(
                  ignoring: collapseT > 0.5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [

              // ── Hero CTA ("Where to?" / "Ride in progress") ── ONE card only
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: RepaintBoundary(child: _buildHeroCTA()),
              ),

              // Verification content now shown inside the hero card

              // ── Scheduled ride indicator (below Where to?) — fades in/out ──
              if (_activeRide == null)
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, anim) =>
                      FadeTransition(opacity: anim, child: SizeTransition(sizeFactor: anim, child: child)),
                  child: _nextScheduledRide != null
                      ? Padding(
                          key: ValueKey('sched_${((_nextScheduledRide!['status'] as String?) ?? 'scheduled').toLowerCase()}'),
                          padding: const EdgeInsets.only(left: 24, right: 24, top: 16),
                          child: _buildScheduledRideIndicator(context),
                        )
                      : const SizedBox.shrink(key: ValueKey('no_scheduled')),
                ),

              // ── Hide everything below when a ride is active ──
              if (_activeRide == null) ...[
              const SizedBox(height: 28),

              // ── Circular action buttons ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: RepaintBoundary(child: _buildCircularActions()),
              ),

              const SizedBox(height: 36),

              // ── Fleet header + cards ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: _buildFleetHeader(),
              ),
                const SizedBox(height: 16),
                AnimatedCrossFade(
                  firstChild: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: RepaintBoundary(child: _buildFleetStack(screenW)),
                  ),
                  secondChild: const SizedBox.shrink(),
                  crossFadeState: _fleetExpanded
                      ? CrossFadeState.showFirst
                      : CrossFadeState.showSecond,
                  duration: const Duration(milliseconds: 300),
                  sizeCurve: Curves.easeInOut,
                ),

                const SizedBox(height: 36),

                // ── Quick access ──
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _buildSectionHeader(S.of(context).quickAccessTitle, null, null),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: RepaintBoundary(child: _buildQuickAccessGrid()),
                ),

                // ── Recent trips ──
                if (_recentTrips.isNotEmpty) ...[
                  const SizedBox(height: 36),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: _buildSectionHeader(
                      S.of(context).recentActivity,
                      null,
                      null,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: RepaintBoundary(child: _buildRecentTimeline()),
                  ),
                ] else if (_loadingSavedData) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 30),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: _gold.withValues(alpha: 0.5),
                          strokeWidth: 2,
                        ),
                      ),
                    ),
                  ),
                ],

                  const SizedBox(height: 32),

                  // ── Dock navigation ──
                  _buildDockNav(context, botPad),
                  SizedBox(height: botPad + 12),
              ], // end if (_activeRide == null)

              if (_activeRide != null)
                const SizedBox(height: 20),
                    ],
                  ),  // close inner Column wrapped by Opacity/IgnorePointer
                ),    // close IgnorePointer
              ),      // close Opacity
                ],
              )),
              ],
            ),
            ]),  // close Stack(children:[ Positioned.fill, CustomScrollView ])
          ),
            ],  // close outer Stack children
          ),    // close outer Stack
        );
      },
    );
  }

  // ════════════════════════════════════════════════════
  //  W I D G E T S
  // ════════════════════════════════════════════════════

  Widget _glowOrb(double size, Color color, double opacity) {
    return RepaintBoundary(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withValues(alpha: opacity),
              Colors.transparent,
            ],
          ),
        ),
      ),
    );
  }

  // ─── Top bar ───
  Widget _buildTopBar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textMain = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final initials = [
      if (_firstName.isNotEmpty) _firstName[0],
      if (_lastName.isNotEmpty) _lastName[0],
    ].join().toUpperCase();
    final displayInitial = initials.isNotEmpty ? initials : '?';
    final displayName = [
      if (_firstName.isNotEmpty) _firstName,
      if (_lastName.isNotEmpty) _lastName,
    ].join(' ');
    final hasLocalPhoto =
        _photoPath != null &&
        _photoPath!.isNotEmpty &&
        !_photoPath!.startsWith('http') &&
        (kIsWeb || File(_photoPath!).existsSync());
    final hasRemotePhoto =
        (_photoUrl != null && _photoUrl!.isNotEmpty && _photoUrl!.startsWith('http')) ||
        UserSession.photoUrlNotifier.value.isNotEmpty;
    final hasPhoto = hasLocalPhoto || hasRemotePhoto;
    final remoteUrl = (_photoUrl != null && _photoUrl!.isNotEmpty && _photoUrl!.startsWith('http'))
        ? _photoUrl!
        : (UserSession.photoUrlNotifier.value.isNotEmpty ? UserSession.photoUrlNotifier.value : null);

    return Row(
      children: [
        // Greeting
        Expanded(
          child: GestureDetector(
            onTap: () async {
              await Navigator.of(
                context,
              ).push(slideFromRightRoute(const AccountScreen()));
              _loadSavedData();
            },
            behavior: HitTestBehavior.opaque,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _getGreeting(context).toUpperCase(),
                  style: TextStyle(
                    color: _gold,
                    fontSize: Responsive.sp(11),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2.0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  displayName.isNotEmpty ? displayName : S.of(context).rider,
                  style: TextStyle(
                    color: textMain,
                    fontSize: Responsive.sp(24),
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),

        // Notification bell
        _glassIconButton(
          Icons.notifications_none_rounded,
          onTap: _openNotificationsSheet,
          badge: _unreadNotifications,
        ),
        const SizedBox(width: 12),

        // Avatar
        GestureDetector(
          onTap: () async {
            await Navigator.of(
              context,
            ).push(slideFromRightRoute(const AccountScreen()));
            _loadSavedData();
          },
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: Responsive.w(44),
                height: Responsive.w(44),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  gradient: hasPhoto
                      ? null
                      : const LinearGradient(colors: [_gold, _goldLight]),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: _gold.withValues(alpha: 0.35),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: hasPhoto
                    ? (hasLocalPhoto && !kIsWeb
                          ? Image.file(
                              File(_photoPath!),
                              fit: BoxFit.cover,
                              width: Responsive.w(44),
                              height: Responsive.w(44),
                              cacheWidth: 200,
                              gaplessPlayback: true,
                              key: ValueKey('${_photoPath}_${UserSession.currentUid}'),
                              frameBuilder:
                                  (context, child, frame, wasSynchronouslyLoaded) {
                                    if (wasSynchronouslyLoaded) return child;
                                    return AnimatedOpacity(
                                      opacity: frame == null ? 0.0 : 1.0,
                                      duration: const Duration(milliseconds: 150),
                                      curve: Curves.easeOutCubic,
                                      child: child,
                                    );
                                  },
                            )
                          : CachedNetworkImage(
                              imageUrl: remoteUrl ?? '',
                              cacheKey: UserSession.currentUid.isNotEmpty
                                  ? 'avatar_${UserSession.currentUid}'
                                  : null,
                              fit: BoxFit.cover,
                              width: Responsive.w(44),
                              height: Responsive.w(44),
                              fadeInDuration: const Duration(milliseconds: 200),
                              key: ValueKey('${remoteUrl}_${UserSession.currentUid}'),
                              placeholder: (_, __) => Container(
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(colors: [_gold, _goldLight]),
                                ),
                                child: Center(
                                  child: Text(
                                    displayInitial,
                                    style: const TextStyle(
                                      color: Colors.black87,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ),
                              errorWidget: (_, __, ___) => Container(
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(colors: [_gold, _goldLight]),
                                ),
                                child: Center(
                                  child: Text(
                                    displayInitial,
                                    style: const TextStyle(
                                      color: Colors.black87,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ),
                            ))
                    : Center(
                        child: Text(
                          displayInitial,
                          style: const TextStyle(
                            color: Colors.black87,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
              ),
              if (_isVerified)
                Positioned(
                  bottom: -1,
                  right: -1,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFFFD700),
                      border: Border.all(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        width: 1.5,
                      ),
                    ),
                    child: const Icon(Icons.check, color: Colors.black, size: 9),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _glassIconButton(IconData icon, {VoidCallback? onTap, int badge = 0}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: Responsive.w(44),
            height: Responsive.w(44),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              boxShadow: isDark
                  ? null
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 8,
                      ),
                    ],
            ),
            child: Icon(
              icon,
              color: Colors.white.withValues(alpha: 0.4),
              size: Responsive.sp(22),
            ),
          ),
          if (badge > 0)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [_gold, _goldLight]),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  badge > 9 ? '9+' : '$badge',
                  style: TextStyle(
                    color: Colors.black87,
                    fontSize: Responsive.sp(9),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _getGreeting(BuildContext context) {
    final hour = DateTime.now().hour;
    final s = S.of(context);
    if (hour < 12) return s.goodMorning;
    if (hour < 18) return s.goodAfternoon;
    return s.goodEvening;
  }

  // ─── Verification blocked dialog ───
  void _showVerificationBlockedDialog() {
    final verStatus = _verificationStatus;
    if (verStatus == 'pending') {
      // Already submitted — show pending message
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1C1E24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: [
              const Icon(Icons.hourglass_top_rounded, color: Color(0xFFE8C547)),
              const SizedBox(width: 10),
              Text(
                S.of(ctx).accountPendingTitle,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ],
          ),
          content: Text(
            S.of(ctx).accountPendingDesc,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(
                S.of(ctx).ok,
                style: const TextStyle(color: Color(0xFFE8C547)),
              ),
            ),
          ],
        ),
      );
    } else {
      // Not yet submitted — launch verification
      _ensureVerified();
    }
  }

  // ─── Hero CTA Card — transforms between "Where to?" and "Ride in progress" ───
  Widget _buildHeroCTA() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final active = _activeRide != null;
    final imminent = _hasImminentRide;
    final zoneBlocked = !_serviceZoneActive && _activeServiceStates.isNotEmpty;
    final verificationBlocked = !_isVerified && !active;
    final disabled = !active && !imminent && (zoneBlocked || verificationBlocked);
    return GestureDetector(
      onTap: () async {
        if (active) {
          _resumeActiveRide();
          return;
        }
        if (verificationBlocked) {
          if (_verificationStatus == 'pending') {
            _showVerificationBlockedDialog();
          } else {
            _ensureVerified();
          }
          return;
        }
        if (imminent) {
          await _openScheduledRideLive();
          return;
        }
        if (zoneBlocked) {
          showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF1C1E24),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Row(
                children: [
                  const Icon(
                    Icons.location_off_rounded,
                    color: Color(0xFFE8C547),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    S.of(ctx).serviceZoneTitle,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ],
              ),
              content: Text(
                S.of(ctx).noServiceState,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(
                    S.of(ctx).understood,
                    style: const TextStyle(color: Color(0xFFE8C547)),
                  ),
                ),
              ],
            ),
          );
          return;
        }
        await _openSearchThenRide();
      },
      child: ListenableBuilder(
        listenable: _shimmerController,
        builder: (context, child) {
          final v = _shimmerController.value;
          return Opacity(
            opacity: (disabled && !verificationBlocked) ? 0.55 : 1.0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOutCubic,
              height: (active || imminent)
                  ? Responsive.h(195)
                  : verificationBlocked
                      ? Responsive.h(_verificationStatus == 'pending' ? 130 : 175)
                      : Responsive.h(155),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: (active || imminent)
                      ? _gold.withValues(alpha: 0.4)
                      : Colors.transparent,
                  width: (active || imminent) ? 1.5 : 0,
                ),
              ),
              child: CustomPaint(
                painter: disabled
                    ? null
                    : _GlowBorderPainter(
                        progress: v,
                        gold: _gold,
                        goldLight: _goldLight,
                        isDark: isDark,
                      ),
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    gradient: isDark
                        ? const LinearGradient(
                            colors: [Color(0xFF141210), Color(0xFF0C0B09)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : LinearGradient(
                            colors: [
                              const Color(0xFF161820),
                              const Color(0xFF1C1E24),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: [
                      BoxShadow(
                        color: (active || imminent)
                            ? _gold.withValues(alpha: 0.15 + 0.1 * ((v * 3.14).clamp(0, 1)))
                            : _gold.withValues(alpha: 0.06 + 0.08 * ((v * 3.14).clamp(0, 1))),
                        blurRadius: (active || imminent) ? 20 + 10 * v : 30 + 15 * v,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    switchInCurve: Curves.easeInOutCubic,
                    switchOutCurve: Curves.easeInOutCubic,
                    transitionBuilder: (child, anim) =>
                        FadeTransition(opacity: anim, child: child),
                    child: active
                        ? _buildHeroRideInProgress()
                        : imminent
                            ? _buildHeroUpcomingRide()
                            : _buildHeroWhereToContent(isDark, disabled, zoneBlocked, verificationBlocked),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ─── "Where to?" content inside the hero card ───
  Widget _buildHeroWhereToContent(bool isDark, bool disabled, bool zoneBlocked, bool verificationBlocked) {
    // When verification is blocked, show verification content inside the card
    if (verificationBlocked) {
      final isPending = _verificationStatus == 'pending';
      return Column(
        key: const ValueKey('hero_verify'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isPending
                      ? _gold.withValues(alpha: 0.15)
                      : Colors.red.withValues(alpha: 0.12),
                ),
                child: Icon(
                  isPending ? Icons.hourglass_top_rounded : Icons.lock_rounded,
                  color: isPending ? _gold : Colors.redAccent,
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isPending
                          ? S.of(context).accountPendingTitle
                          : S.of(context).verifyAccountTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isPending
                          ? S.of(context).accountPendingDesc
                          : S.of(context).verifyAccountDesc,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
                        height: 1.3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (!isPending) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  elevation: 0,
                ),
                onPressed: () => _ensureVerified(),
                child: Text(
                  S.of(context).verifyNow,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
              ),
            ),
          ],
        ],
      );
    }

    return Row(
      key: const ValueKey('hero_where_to'),
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                S.of(context).whereToQuestion,
                style: TextStyle(
                  color: disabled
                      ? Colors.white.withValues(alpha: 0.25)
                      : isDark
                      ? Colors.white
                      : const Color(0xFF1C1C1E),
                  fontSize: Responsive.sp(28),
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(height: 8),
              if (disabled && zoneBlocked)
                Row(
                  children: [
                    Icon(
                      Icons.location_off_rounded,
                      color: Colors.white.withValues(alpha: 0.35),
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        S.of(context).noDriversInState,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.35),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 2,
                      ),
                    ),
                  ],
                )
              else ...[
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: () {},
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    padding: const EdgeInsets.all(3),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _nowLaterPill(
                          S.of(context).nowLabel,
                          Icons.bolt_rounded,
                          _rideNow,
                          () {
                            if (!_rideNow) _setState(() => _rideNow = true);
                          },
                        ),
                        _nowLaterPill(
                          S.of(context).laterLabel,
                          Icons.schedule_rounded,
                          !_rideNow,
                          () {
                            if (_rideNow) {
                              _setState(() => _rideNow = false);
                              _showScheduleSheet();
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.10),
            ),
          ),
          child: const Icon(
            Icons.arrow_forward_ios_rounded,
            color: Colors.white,
            size: 16,
          ),
        ),
      ],
    );
  }

  String _getCarAssetForRideType(String rideType) {
    switch (rideType.toLowerCase()) {
      case 'vip':
        return 'assets/images/cruisert1.png';
      case 'premium':
        return 'assets/images/cruisert2.png';
      case 'comfort':
        return 'assets/images/cruisert3.png';
      default:
        return 'assets/images/cruisert2.png';
    }
  }

  Widget _buildProgressBar() {
    final progress = _tripProgress.clamp(0.0, 1.0);
    const barH = 14.0;
    const carSize = 38.0;
    // Total height accounts for car overflowing the bar
    const totalH = carSize;

    return LayoutBuilder(
      builder: (_, constraints) {
        final barW = constraints.maxWidth;
        // Car right edge at tip of progress fill
        final carX = (barW * progress - carSize + 4).clamp(0.0, barW - carSize);

        return SizedBox(
          height: totalH,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Bar track — vertically centered
              Positioned(
                left: 0,
                right: 0,
                top: (totalH - barH) / 2,
                height: barH,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A2A2A),
                    borderRadius: BorderRadius.circular(barH / 2),
                  ),
                ),
              ),
              // Animated gold fill
              Positioned(
                left: 0,
                top: (totalH - barH) / 2,
                height: barH,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 1000),
                  curve: Curves.easeInOut,
                  width: barW * progress,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(barH / 2),
                    gradient: const LinearGradient(
                      colors: [
                        Color(0xFFFFC200),
                        Color(0xFFFFD700),
                        Color(0xFFFFE566),
                      ],
                    ),
                  ),
                ),
              ),
              // Car image — bigger, stuck to the tip of the progress bar
              AnimatedPositioned(
                duration: const Duration(milliseconds: 1000),
                curve: Curves.easeInOut,
                left: carX,
                top: (totalH - carSize) / 2,
                child: Image.asset(
                  _getCarAssetForRideType(_activeRide?.rideName ?? ''),
                  width: carSize,
                  height: carSize,
                  fit: BoxFit.contain,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ─── "Ride in progress" content inside the hero card ───
  Widget _buildHeroRideInProgress() {
    return Column(
      key: const ValueKey('hero_ride_active'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // Top row: icon + text + chevron
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Logo image in rounded square
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset(
                'assets/images/logoapp.png',
                width: 42,
                height: 42,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    S.of(context).rideInProgressTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    S.of(context).rideInProgressSubtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.38),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.24),
              size: 20,
            ),
          ],
        ),
        const SizedBox(height: 14),
        // Progress bar with car
        _buildProgressBar(),
        const SizedBox(height: 8),
        // Time labels
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              S.of(context).driverLabel,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.24),
                fontSize: 11,
              ),
            ),
            Text(
              _remainingLabel,
              style: const TextStyle(
                color: Color(0xFFFFD700),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              (_activeRide?.phase == 'onTrip' || _activeRide?.phase == 'nearDestination')
                  ? 'Dropoff'
                  : 'Pickup',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.24),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ─── "Your ride starts in X min" card for imminent scheduled rides ───
  Widget _buildHeroUpcomingRide() {
    final mins = _minutesUntilRide;
    final isEs = Localizations.localeOf(context).languageCode == 'es';
    final timeStr = mins < 60 ? '$mins min' : '${mins ~/ 60}h ${mins % 60}m';
    final title = isEs
        ? 'Tu viaje empieza en $timeStr'
        : 'Your ride starts in $timeStr';
    final subtitle = isEs ? 'Toca para ver detalles' : 'Tap for details';

    return Column(
      key: const ValueKey('hero_upcoming_ride'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // Top row: icon + text + chevron
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset(
                'assets/images/logoapp.png',
                width: 42,
                height: 42,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.38),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.24),
              size: 20,
            ),
          ],
        ),
        const SizedBox(height: 14),
        // Progress bar (static at 0)
        _buildUpcomingProgressBar(),
        const SizedBox(height: 8),
        // Labels: Driver — X min — Pickup
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              S.of(context).driverLabel,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.24),
                fontSize: 11,
              ),
            ),
            Text(
              '$mins ${S.of(context).minSuffix}',
              style: const TextStyle(
                color: Color(0xFFFFD700),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              S.of(context).pickupLabel,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.24),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildUpcomingProgressBar() {
    // Animated pulsing bar at ~10% to indicate "waiting"
    const barH = 14.0;
    const carSize = 38.0;
    const totalH = carSize;

    return LayoutBuilder(
      builder: (_, constraints) {
        final barW = constraints.maxWidth;
        const progress = 0.05; // small sliver to show "starting soon"
        final carX = (barW * progress - carSize + 4).clamp(0.0, barW - carSize);

        return SizedBox(
          height: totalH,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Bar track
              Positioned(
                left: 0, right: 0,
                top: (totalH - barH) / 2,
                height: barH,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A2A2A),
                    borderRadius: BorderRadius.circular(barH / 2),
                  ),
                ),
              ),
              // Pulsing gold fill
              Positioned(
                left: 0,
                top: (totalH - barH) / 2,
                height: barH,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 1000),
                  curve: Curves.easeInOut,
                  width: barW * progress,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(barH / 2),
                    gradient: const LinearGradient(
                      colors: [
                        Color(0xFFFFC200),
                        Color(0xFFFFD700),
                        Color(0xFFFFE566),
                      ],
                    ),
                  ),
                ),
              ),
              // Car at start
              Positioned(
                left: carX,
                top: (totalH - carSize) / 2,
                child: Image.asset(
                  'assets/images/cruisert2.png',
                  width: carSize,
                  height: carSize,
                  fit: BoxFit.contain,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ─── Circular action buttons ───
  
  String get _remainingLabel {
    if (_remainingSeconds <= 0) return '0 min';
    final mins = _remainingSeconds ~/ 60;
    return '$mins min';
  }

  Widget _buildCircularActions() {
    final active = _activeRide != null;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Bolt — flashes every 2s
        _animatedCircleAction(
          child: AnimatedBuilder(
            animation: _boltFlashCtrl,
            builder: (context, child) {
              final glow = _boltFlashCtrl.value;
              return ShaderMask(
                shaderCallback: (bounds) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color.lerp(
                      const Color(0xFFFBE47A),
                      Colors.white,
                      glow * 0.7,
                    )!,
                    Color.lerp(
                      const Color(0xFFE8C547),
                      const Color(0xFFFBE47A),
                      glow,
                    )!,
                  ],
                ).createShader(bounds),
                child: Icon(Icons.bolt_rounded, color: Colors.white, size: 26),
              );
            },
          ),
          label: S.of(context).fastRide,
          disabled: active || !_driversOnline,
          onTap: () async {
            if (active) return;
            if (_openingRideFlow) return; // share the same re-entry guard
            // Re-check drivers right before opening so a stale cached
            // _driversOnline=true (from up to 120s ago) doesn't push the
            // rider into a flow that has nobody to match with.
            await _checkDriversOnline();
            if (!mounted) return;
            if (!_driversOnline) {
              _showFastRideUnavailableDialog();
              return;
            }
            // 2026-04-26: Priority now opens the *standard* Request Now
            // flow (pickup/dropoff search → RideRequestScreen with all
            // tier options). The old `fastRide: true` branch jumped
            // straight into ride_request without picking pickup/dropoff
            // first, so for users who hadn't searched yet the sheet had
            // no rideOptions and showed an empty mapped view. Routing
            // through _openSearchThenRide() keeps the UX consistent
            // with the hero "Where to?" CTA and the Now toggle.
            await _openSearchThenRide();
          },
        ),
        // Clock — real clock animation with ticking hands
        _animatedCircleAction(
          child: AnimatedBuilder(
            animation: _clockRotateCtrl,
            builder: (context, child) {
              return SizedBox(
                width: 26,
                height: 26,
                child: CustomPaint(
                  painter: _ClockPainter(_clockRotateCtrl.value),
                ),
              );
            },
          ),
          label: S.of(context).schedule,
          disabled: active,
          onTap: _openScheduleFlow,
        ),
        // 10% off — shimmer animation, disabled after use, shows trip counter
        _animatedCircleAction(
          child: _promoUsed
              ? Stack(
                  alignment: Alignment.center,
                  children: [
                    ShaderMask(
                      shaderCallback: (bounds) => LinearGradient(
                        colors: [Colors.grey.shade600, Colors.grey.shade500],
                      ).createShader(bounds),
                      child: const Icon(
                        Icons.local_offer_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                    // Mini trip counter badge
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2E2E2E),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFFE8C547),
                            width: 1.5,
                          ),
                        ),
                        child: Center(
                          child: Text(
                            '${3 - _promoTripsLeft}',
                            style: const TextStyle(
                              color: Color(0xFFE8C547),
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : AnimatedBuilder(
                  animation: _promoShimmerCtrl,
                  builder: (context, child) {
                    final v = _promoShimmerCtrl.value;
                    return ShaderMask(
                      shaderCallback: (bounds) => LinearGradient(
                        begin: Alignment(-1.0 + 2.0 * v, 0),
                        end: Alignment(1.0 + 2.0 * v, 0),
                        colors: const [
                          Color(0xFFE8C547),
                          Color(0xFFFBE47A),
                          Colors.white,
                          Color(0xFFFBE47A),
                          Color(0xFFE8C547),
                        ],
                        stops: const [0.0, 0.3, 0.5, 0.7, 1.0],
                      ).createShader(bounds),
                      child: const Icon(
                        Icons.local_offer_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                    );
                  },
                ),
          label: _promoUsed ? '${3 - _promoTripsLeft}/3 ${S.of(context).promoTrips}' : S.of(context).promoOff,
          disabled: active || _promoUsed,
          onTap: _promoUsed ? _showPromoLockedDialog : _showPromoWelcomeDialog,
        ),
      ],
    );
  }

  Widget _nowLaterPill(
    String label,
    IconData icon,
    bool active,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? _gold : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: active
                  ? Colors.black
                  : Colors.white.withValues(alpha: 0.45),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: active
                    ? Colors.black
                    : Colors.white.withValues(alpha: 0.45),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _animatedCircleAction({
    required Widget child,
    required String label,
    required VoidCallback onTap,
    bool disabled = false,
  }) {
    return GestureDetector(
      onTap: disabled ? null : onTap,
      child: Opacity(
        opacity: disabled ? 0.4 : 1.0,
        child: Column(
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF4A4A4A),
                    Color(0xFF3A3A3A),
                    Color(0xFF2E2E2E),
                    Color(0xFF3A3A3A),
                  ],
                  stops: [0.0, 0.3, 0.7, 1.0],
                ),
                border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.06),
                    blurRadius: 4,
                    offset: const Offset(0, -1),
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: child,
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                color: disabled
                    ? Colors.white.withValues(alpha: 0.25)
                    : Colors.white.withValues(alpha: 0.55),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  // ─── Section header ───
  Widget _buildSectionHeader(
    String title,
    String? action,
    VoidCallback? onAction,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Container(
          width: 4,
          height: 20,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [_gold, _goldLight],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          title,
          style: TextStyle(
            color: isDark ? Colors.white : const Color(0xFF1C1C1E),
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
        const Spacer(),
        if (action != null)
          GestureDetector(
            onTap: onAction,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _gold.withValues(alpha: 0.15)),
              ),
              child: Text(
                action,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ─── Fleet header with collapse/expand toggle (TAP to toggle) ───
  Widget _buildFleetHeader() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () {
        _setState(() => _fleetExpanded = !_fleetExpanded);
      },
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          Container(
            width: 4,
            height: 20,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [_gold, _goldLight],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            S.of(context).chooseRide,
            style: TextStyle(
              color: isDark ? Colors.white : const Color(0xFF1C1C1E),
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const Spacer(),
          AnimatedRotation(
            turns: _fleetExpanded ? 0.5 : 0.0, // Arrow up when expanded, down when collapsed
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            child: Icon(
              Icons.keyboard_arrow_down_rounded,
              color: Colors.white.withValues(alpha: 0.5),
              size: 24,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Fleet: Redesigned professional vehicle cards ───
  Widget _buildFleetStack(double screenW) {
    final active = _activeRide != null;
    // Unified dark card background for all tiers
    const cardBg = [Color(0xFF1A1D24), Color(0xFF252A35)];

    final s = S.of(context);
    final vehicles = [
      {
        'tier': 'VIP',
        'desc': s.vipDesc,
        'features': s.vipFeatures,
        'idx': 0,
        'accent': _gold,
        'image': 'cruise_3.png',
        'gradient': const [Color(0xFFE8C547), Color(0xFFD4A574)],
      },
      {
        'tier': 'PREMIUM',
        'desc': s.premiumDesc,
        'features': s.premiumFeatures,
        'idx': 1,
        'accent': const Color(0xFFCECECE),
        'image': 'cruise_7.png',
        'gradient': const [Color(0xFFE8E8E8), Color(0xFFB0B0B0)],
      },
      {
        'tier': 'COMFORT',
        'desc': s.comfortDesc,
        'features': s.comfortFeatures,
        'idx': 2,
        'accent': const Color(0xFF4CAF50),
        'image': 'cruise_6.png',
        'gradient': const [Color(0xFF66BB6A), Color(0xFF388E3C)],
      },
    ];

    // 1:1 with web — 3 cards in a horizontal row
    return Row(
      children: vehicles.map((v) {
        final accent = v['accent'] as Color;
        final idx = v['idx'] as int;
        final tier = v['tier'] as String;
        final gradient = v['gradient'] as List<Color>;
        final isVIP = tier == 'VIP';
        final isPremium = tier == 'PREMIUM';
        final isComfort = tier == 'COMFORT';

        // ── Static tier badge (no shimmer / sweep / pulse animations) ──
        // Fixed 78x22 size on every tier so VIP / PREMIUM / COMFORT
        // line up identically across the row.
        final Widget animatedBadge = SizedBox(
          width: 78,
          height: 22,
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              gradient: isVIP
                  ? const LinearGradient(
                      colors: [Color(0xFF1A1A1A), Color(0xFF000000)],
                    )
                  : isPremium
                      ? const LinearGradient(
                          colors: [
                            Color(0xFFF5DC7A),
                            Color(0xFFE8C547),
                            Color(0xFFB08800),
                          ],
                        )
                      : const LinearGradient(
                          colors: [Color(0xFFE8E8E8), Color(0xFFB0B0B0)],
                        ),
              borderRadius: BorderRadius.circular(6),
              border: isVIP
                  ? Border.all(
                      color:
                          const Color(0xFFE8C547).withValues(alpha: 0.3),
                      width: 1,
                    )
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isVIP)
                  const Icon(Icons.diamond, size: 9, color: Colors.white)
                else
                  Text(
                    isPremium ? '★' : '✦',
                    style: TextStyle(
                      color: isPremium
                          ? Colors.black
                          : const Color(0xFF1A1A1A),
                      fontSize: 8,
                      height: 1,
                    ),
                  ),
                const SizedBox(width: 3),
                Text(
                  tier,
                  style: TextStyle(
                    color: isVIP
                        ? Colors.white
                        : (isPremium
                            ? Colors.black
                            : const Color(0xFF1A1A1A)),
                    fontSize: 8,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.64,
                  ),
                ),
              ],
            ),
          ),
        );

        // ── Static card — no AnimatedBuilder wrapper ──
        // Map tier → ride option ID for pre-selection
        final rideId = isVIP ? 'suburban' : isPremium ? 'camry' : 'fusion';
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(
              right: idx < 2 ? 8 : 0,
            ),
          child: IgnorePointer(
            ignoring: active,
            child: Opacity(
              opacity: active ? 0.45 : 1.0,
              child: GestureDetector(
                onTap: () => _openSearchThenRide(rideId: rideId),
                child: Container(
              // Fixed equal height across all 3 tiers — VIP / PREMIUM /
              // COMFORT now line up identically.
              height: 168,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: cardBg,
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: _gold.withValues(alpha: 0.30),
                  width: 1.5,
                ),
                // Only a soft black drop — gold halo behind the card was
                // dropped per design feedback so the 3 cards sit cleanly
                // on the black sheet background.
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Car image with ground-shadow ellipse — slightly
                    // bigger than before (130x90) for more visual weight.
                    SizedBox(
                      width: 130,
                      height: 90,
                      child: Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Container(
                              width: 96,
                              height: 10,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(50),
                                gradient: RadialGradient(
                                  colors: [
                                    Colors.black.withValues(alpha: 0.55),
                                    Colors.black.withValues(alpha: 0.0),
                                  ],
                                  stops: const [0.0, 1.0],
                                ),
                              ),
                            ),
                          ),
                          Image.asset(
                            'assets/images/${v['image']}',
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.high,
                            isAntiAlias: true,
                            alignment: Alignment.center,
                            cacheWidth: 360,
                            errorBuilder: (ctx, err, st) => Icon(
                              Icons.directions_car_rounded,
                              color: accent.withValues(alpha: 0.5),
                              size: 40,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      isVIP
                          ? 'BLACK'
                          : isPremium
                              ? 'PREMIUM'
                              : 'STANDARD',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    animatedBadge,
                  ],
                ),
              ),
            ),
              ),
            ),
          ),
        ),
        );
      }).toList(),
    );
  }

  // ─── Quick access grid (Home, Work, places) ───
  Widget _buildQuickAccessGrid() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _quickAccessTile(
                Icons.home_rounded,
                S.of(context).homeLabel,
                _homeFavorite?.address ?? S.of(context).addLabel,
                _gold,
                _openOrSaveHomeShortcut,
                onEdit: _editHomeAddress,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _quickAccessTile(
                Icons.work_rounded,
                S.of(context).workLabel,
                _workFavorite?.address ?? S.of(context).addLabel,
                _goldLight,
                _openOrSaveWorkShortcut,
                onEdit: _editWorkAddress,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _quickAccessTile(
                Icons.star_rounded,
                _place1Favorite?.label ?? S.of(context).place1Label,
                _place1Favorite?.address ?? S.of(context).addLabel,
                _gold,
                _openOrSavePlace1Shortcut,
                onEdit: _editPlace1Address,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _quickAccessTile(
                Icons.star_rounded,
                _place2Favorite?.label ?? S.of(context).place2Label,
                _place2Favorite?.address ?? S.of(context).addLabel,
                _goldLight,
                _openOrSavePlace2Shortcut,
                onEdit: _editPlace2Address,
              ),
            ),
          ],
        ),
        // Frequent destinations below
        if (_topDestinations.isNotEmpty) ...[
          const SizedBox(height: 12),
          ..._topDestinations.take(2).map((d) {
            final shortName = d.address.split(',').first;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GestureDetector(
                onTap: () => _openMapWithDropoff(d.address),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.04)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                    boxShadow: isDark
                        ? null
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.03),
                              blurRadius: 8,
                            ),
                          ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: _gold.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.near_me_rounded,
                          color: _gold,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              shortName,
                              style: TextStyle(
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF1C1C1E),
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${d.count} ${S.of(context).tripsLabel}',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.45),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: Colors.white.withValues(alpha: 0.4),
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ],
    );
  }

  Widget _quickAccessTile(
    IconData icon,
    String title,
    String subtitle,
    Color accent,
    VoidCallback onTap, {
    VoidCallback? onEdit,
  }) {
    final hasAddress = subtitle != 'Add' && subtitle.trim().isNotEmpty;
    return GestureDetector(
      onTap: () {
        if (!hasAddress) {
          onTap();
          return;
        }
        _showPlaceOptions(title, subtitle, onEdit ?? onTap);
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _gold.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _gold.withValues(alpha: 0.18)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: _gold, size: 22),
            const SizedBox(height: 6),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              subtitle,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 11,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeOptionBtn(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool highlight = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: highlight
                ? _gold.withValues(alpha: 0.15)
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: highlight
                  ? _gold.withValues(alpha: 0.30)
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: highlight ? _gold : Colors.white, size: 20),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  color: highlight ? _gold : Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Recent trips timeline ───
  Widget _buildRecentTimeline() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final trips = _recentTrips.take(4).toList();
    return Column(
      children: trips.asMap().entries.map((entry) {
        final i = entry.key;
        final trip = entry.value;
        final shortDest = trip.dropoff.split(',').first;
        final isLast = i == trips.length - 1;

        return GestureDetector(
          onTap: () => _openTripReceipt(trip),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Timeline dot + line
                SizedBox(
                  width: 24,
                  child: Column(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        margin: const EdgeInsets.only(top: 8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            colors: [_gold, _goldLight],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: _gold.withValues(alpha: 0.4),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                      if (!isLast)
                        Expanded(
                          child: Container(
                            width: 1.5,
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            color: Colors.white.withValues(alpha: 0.1),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                // Trip card
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.04)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.1),
                      ),
                      boxShadow: isDark
                          ? null
                          : [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.03),
                                blurRadius: 8,
                              ),
                            ],
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                shortDest,
                                style: TextStyle(
                                  color: isDark
                                      ? Colors.white
                                      : const Color(0xFF1C1C1E),
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                trip.rideName,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.45),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: _gold.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            trip.price,
                            style: const TextStyle(
                              color: _gold,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  // ─── Live map card ───
  Widget _buildLiveMapCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Container(
        height: 180,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Stack(
          children: [
            if (_currentLatLng == null)
              Container(
                color: const Color(0xFF0D0E14),
                child: Center(
                  child: _locationError != null
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.location_off_rounded,
                              color: Colors.white.withValues(alpha: 0.5),
                              size: 28,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _locationError!,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 12),
                            GestureDetector(
                              onTap: () {
                                _setState(() => _locationError = null);
                                _fetchCurrentLocation();
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: _gold.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  S.of(context).retry,
                                  style: const TextStyle(
                                    color: _gold,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        )
                      : const CircularProgressIndicator(
                          color: _gold,
                          strokeWidth: 2,
                        ),
                ),
              )
            else
              mapbox.MapWidget(
                styleUri: MapboxConfig.styleDark,
                cameraOptions: mapbox.CameraOptions(
                  center: mapbox.Point(coordinates: mapbox.Position(_currentLatLng!.longitude, _currentLatLng!.latitude)),
                  zoom: 15.0,
                ),
                onMapCreated: (ctrl) async {
                  _miniMapController = ctrl;
                  ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
                  ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
                  ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
                  ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));
                  _miniMapAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
                  // GoldLocationDot removed — LocationPuck via onStyleLoadedListener
                },
                onStyleLoadedListener: (_) async {
                  if (_miniMapController != null) {
                    await _applyDarkNavyGoldTheme(_miniMapController!);
                    try {
                      final puckImg = await _buildGoldPuckImage();
                      await _miniMapController!.location.updateSettings(mapbox.LocationComponentSettings(
                        enabled: true,
                        pulsingEnabled: true,
                        pulsingColor: const Color(0xFFE8C547).toARGB32(),
                        pulsingMaxRadius: 20.0,
                        locationPuck: mapbox.LocationPuck(
                          locationPuck2D: mapbox.LocationPuck2D(topImage: puckImg),
                        ),
                      ));
                    } catch (_) {}
                  }
                },
                gestureRecognizers: const {},
              ),
            // Badge
            Positioned(
              bottom: 12,
              left: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF0D0E14).withValues(alpha: 0.85)
                      : Colors.white.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                  boxShadow: isDark
                      ? null
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 8,
                          ),
                        ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _gold,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.5),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      S.of(context).liveLocation,
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF1C1C1E),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Scheduled ride indicator ───
  Widget _buildScheduledRideIndicator(BuildContext ctx) {
    final ride = _nextScheduledRide!;
    final sa = ride['scheduled_at']?.toString() ?? '';
    final dt = DateTime.tryParse(sa);
    final isEs = Localizations.localeOf(ctx).languageCode == 'es';
    final status = (ride['status'] as String? ?? 'scheduled').toLowerCase();
    final hasDriver = status == 'scheduled_accepted' || status == 'driver_assigned' ||
        status == 'accepted' || status == 'en_route' || status == 'en_route_to_pickup' ||
        status == 'driver_en_route' || status == 'arriving' || status == 'arrived' ||
        status == 'driver_arrived' || status == 'in_trip' || status == 'in_progress';

    final driverName = (ride['driver_name'] as String?)?.split(' ').first ?? '';
    final label = hasDriver
        ? (isEs
            ? '${driverName.isNotEmpty ? '$driverName está' : 'Tu conductor está'} confirmado para tu viaje'
            : '${driverName.isNotEmpty ? '$driverName is' : 'Your driver is'} confirmed for your ride')
        : (isEs ? 'Tienes un viaje reservado' : 'You have a scheduled ride');
    final dateStr = dt != null
        ? DateFormat(isEs ? "d 'de' MMM, h:mm a" : 'MMM d, h:mm a',
                isEs ? 'es' : 'en')
            .format(dt.toLocal())
        : '';

    final accent = hasDriver ? const Color(0xFF4CAF50) : _gold;

    return GestureDetector(
      onTap: () async {
        await _openScheduledRideLive();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withValues(alpha: 0.30), width: 1),
        ),
        child: Row(
          children: [
            Icon(
              hasDriver ? Icons.check_circle_rounded : Icons.calendar_today_rounded,
              color: accent,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                        color: accent,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      )),
                  if (dateStr.isNotEmpty)
                    Text(dateStr,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 12,
                        )),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: accent.withValues(alpha: 0.6), size: 22),
          ],
        ),
      ),
    );
  }

  // ─── Dock-style bottom nav with animated gold pill ───
  Widget _buildDockNav(BuildContext context, double bottomPad) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final s = S.of(context);
    final items = [
      (icon: Icons.explore_rounded, label: s.rideLabel),
      (icon: Icons.calendar_today_rounded, label: s.schedule),
      (icon: Icons.person_rounded, label: s.accountLabel),
    ];

    return Container(
      margin: EdgeInsets.fromLTRB(40, 0, 40, bottomPad + 16),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF161820),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.12),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(items.length, (i) {
          final active = i == _dockIndex;
          return GestureDetector(
            onTap: () => _onDockTap(i),
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.symmetric(
                horizontal: active ? 20 : 18,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                gradient: active
                    ? const LinearGradient(colors: [_gold, _goldLight])
                    : null,
                borderRadius: BorderRadius.circular(22),
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: _gold.withValues(alpha: 0.3),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Icon(
                      items[i].icon,
                      key: ValueKey('dock_icon_${i}_$active'),
                      color: active
                          ? Colors.black87
                          : Colors.white.withValues(alpha: 0.5),
                      size: 20,
                    ),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    child: active
                        ? Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              items[i].label,
                              style: const TextStyle(
                                color: Colors.black87,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ─── Top-down car silhouette drawn via CustomPainter ───
class _CarIconPainter extends CustomPainter {
  static const _color = Color(0xFFFFD700);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint()
      ..color = _color
      ..style = PaintingStyle.fill;

    // ── Body (rounded rect, slightly narrower at front) ──
    final body = Path()
      ..moveTo(w * 0.22, h * 0.18)
      ..quadraticBezierTo(w * 0.28, h * 0.04, w * 0.50, h * 0.04)
      ..quadraticBezierTo(w * 0.72, h * 0.04, w * 0.78, h * 0.18)
      ..lineTo(w * 0.82, h * 0.32)
      ..lineTo(w * 0.84, h * 0.72)
      ..quadraticBezierTo(w * 0.84, h * 0.94, w * 0.72, h * 0.96)
      ..lineTo(w * 0.28, h * 0.96)
      ..quadraticBezierTo(w * 0.16, h * 0.94, w * 0.16, h * 0.72)
      ..lineTo(w * 0.18, h * 0.32)
      ..close();
    canvas.drawPath(body, paint);

    // ── Windshield (darker inset) ──
    final windshield = Paint()
      ..color = _color.withValues(alpha: 0.35)
      ..style = PaintingStyle.fill;
    final ws = Path()
      ..moveTo(w * 0.30, h * 0.20)
      ..quadraticBezierTo(w * 0.50, h * 0.12, w * 0.70, h * 0.20)
      ..lineTo(w * 0.68, h * 0.34)
      ..lineTo(w * 0.32, h * 0.34)
      ..close();
    canvas.drawPath(ws, windshield);

    // ── Rear window ──
    final rw = Path()
      ..moveTo(w * 0.32, h * 0.72)
      ..lineTo(w * 0.68, h * 0.72)
      ..lineTo(w * 0.66, h * 0.82)
      ..quadraticBezierTo(w * 0.50, h * 0.86, w * 0.34, h * 0.82)
      ..close();
    canvas.drawPath(rw, windshield);

    // ── Wheels (4 dark rounded rects) ──
    final wheelPaint = Paint()
      ..color = const Color(0xFF1A1A1A)
      ..style = PaintingStyle.fill;
    final wheelW = w * 0.10;
    final wheelH = h * 0.14;
    final r = Radius.circular(wheelW * 0.4);
    // Front-left
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.10, h * 0.24, wheelW, wheelH), r),
      wheelPaint);
    // Front-right
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.80, h * 0.24, wheelW, wheelH), r),
      wheelPaint);
    // Rear-left
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.10, h * 0.64, wheelW, wheelH), r),
      wheelPaint);
    // Rear-right
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.80, h * 0.64, wheelW, wheelH), r),
      wheelPaint);
  }

  @override
  bool shouldRepaint(_CarIconPainter old) => false;
}

// ════════════════════════════════════════════════════════════
//  RIDE CAR ICON — uses the detail painter above
// ════════════════════════════════════════════════════════════

class RideCarIcon extends StatelessWidget {
  final double size;
  const RideCarIcon({this.size = 28, super.key});

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(size, size),
    painter: _CarIconPainter(),
  );
}
