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
        _updateMiniMapAnnotation();
      },
      onStyleLoadedListener: (_) async {
        if (_miniMapController != null) {
          await _applyDarkNavyGoldTheme(_miniMapController!);
        }
      },
    );
  }

  // "Where to?" / "Ride in progress" search bar floating over the map
  Widget _buildWhereToBar() {
    final active = _activeRide != null;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOutCubic,
      height: 48,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1C22),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: active
              ? _gold.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.08),
          width: active ? 1.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: active
                ? _gold.withValues(alpha: 0.10)
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
        child: active ? _buildRideActiveContent() : _buildWhereToContent(),
      ),
    );
  }

  // Normal "Where to?" search bar content
  Widget _buildWhereToContent() {
    return GestureDetector(
      key: const ValueKey('where_to'),
      onTap: _openSearchThenRide,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          const SizedBox(width: 16),
          Icon(Icons.search_rounded,
              color: Colors.white.withValues(alpha: 0.5), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Where to?',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _gold.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.schedule_rounded, color: _gold, size: 14),
                const SizedBox(width: 4),
                Text('Now',
                    style: TextStyle(
                        color: _gold,
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
              ],
            ),
          ),
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
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _gold.withValues(alpha: 0.15),
              border: Border.all(color: _gold.withValues(alpha: 0.4)),
            ),
            child: const Icon(Icons.directions_car_rounded,
                color: _gold, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Ride in progress',
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
        return DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF0A0B10),
            borderRadius: BorderRadius.vertical(top: Radius.circular(r)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.65),
                blurRadius: 32,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.vertical(top: Radius.circular(r)),
            child: CustomScrollView(
              controller: sc,
              physics: const BouncingScrollPhysics(
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
              const SizedBox(height: 24),

              // ── Hero CTA ("Where to?" / "Ride in progress") ── ONE card only
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: RepaintBoundary(child: _buildHeroCTA()),
              ),

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
                  child: _buildSectionHeader('Quick Access', null, null),
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
                ],
              )),
              ],
            ),
          ),
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
    final hasPhoto =
        _photoPath != null &&
        _photoPath!.isNotEmpty &&
        (kIsWeb || File(_photoPath!).existsSync());

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
                  _getGreeting().toUpperCase(),
                  style: TextStyle(
                    color: _gold,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2.0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  displayName.isNotEmpty ? displayName : 'Rider',
                  style: TextStyle(
                    color: textMain,
                    fontSize: 24,
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
                width: 44,
                height: 44,
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
                    ? (kIsWeb
                          ? CachedNetworkImage(
                              imageUrl: _photoPath!,
                              cacheKey: UserSession.currentUid.isNotEmpty
                                  ? 'avatar_${UserSession.currentUid}'
                                  : null,
                              fit: BoxFit.cover,
                              width: 44,
                              height: 44,
                              fadeInDuration: const Duration(milliseconds: 200),
                              key: ValueKey('${_photoPath}_${UserSession.currentUid}'),
                            )
                          : Image.file(
                              File(_photoPath!),
                              fit: BoxFit.cover,
                              width: 44,
                              height: 44,
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
            width: 44,
            height: 44,
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
              size: 22,
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
                  style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  // ─── Hero CTA Card — transforms between "Where to?" and "Ride in progress" ───
  Widget _buildHeroCTA() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final active = _activeRide != null;
    final verifyDisabled = !_isVerified;
    final zoneBlocked = !_serviceZoneActive && _activeServiceStates.isNotEmpty;
    final disabled = !active && (verifyDisabled || zoneBlocked);
    return GestureDetector(
      onTap: () async {
        if (active) {
          _resumeActiveRide();
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
            opacity: disabled ? 0.55 : 1.0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOutCubic,
              height: active ? 195 : 140,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: active
                      ? _gold.withValues(alpha: 0.4)
                      : Colors.transparent,
                  width: active ? 1.5 : 0,
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
                        color: active
                            ? _gold.withValues(alpha: 0.15 + 0.1 * ((v * 3.14).clamp(0, 1)))
                            : _gold.withValues(alpha: 0.06 + 0.08 * ((v * 3.14).clamp(0, 1))),
                        blurRadius: active ? 20 + 10 * v : 30 + 15 * v,
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
                        : _buildHeroWhereToContent(isDark, disabled, zoneBlocked),
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
  Widget _buildHeroWhereToContent(bool isDark, bool disabled, bool zoneBlocked) {
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
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(height: 8),
              if (disabled)
                Row(
                  children: [
                    Icon(
                      zoneBlocked
                          ? Icons.location_off_rounded
                          : Icons.lock_rounded,
                      color: Colors.white.withValues(alpha: 0.35),
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        zoneBlocked
                            ? S.of(context).noDriversInState
                            : S.of(context).verifyIdentityToRide,
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
                          'Now',
                          Icons.bolt_rounded,
                          _rideNow,
                          () {
                            if (!_rideNow) _setState(() => _rideNow = true);
                          },
                        ),
                        _nowLaterPill(
                          'Later',
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
    const carSize = 40.0;
    const barH = 6.0;
    const totalH = carSize + 8;

    return LayoutBuilder(
      builder: (_, constraints) {
        final barW = constraints.maxWidth;
        // Car center sits at the leading edge of the fill (tip of progress)
        final carX = (barW * progress - carSize / 2).clamp(0.0, barW - carSize);

        return SizedBox(
          height: totalH,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Bar track
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  height: barH,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A2A2A),
                    borderRadius: BorderRadius.circular(barH / 2),
                  ),
                ),
              ),
              // Animated yellow fill
              Positioned(
                left: 0,
                bottom: 0,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 1000),
                  curve: Curves.easeInOut,
                  width: barW * progress,
                  height: barH,
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
              // Car pin at leading edge — NO glow, NO shadow
              AnimatedPositioned(
                duration: const Duration(milliseconds: 1000),
                curve: Curves.easeInOut,
                left: carX,
                bottom: barH - 10,
                child: const RideCarIcon(size: 40),
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
            // Clean car icon — no border, no glow
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: const Center(
                child: RideCarIcon(size: 32),
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
              'Now',
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
              'Destination',
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
            if (!_driversOnline) {
              _showFastRideUnavailableDialog();
              return;
            }
            if (!await _ensureVerified()) return;
            if (!mounted) return;
            Navigator.of(
              context,
            ).push(slideUpFadeRoute(const RideRequestScreen(fastRide: true)));
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

    final vehicles = [
      {
        'tier': 'VIP',
        'desc': 'Luxury SUV with premium amenities',
        'features': 'Spacious • Leather • Snacks & Drinks',
        'idx': 0,
        'accent': _gold,
        'image': 'cruise_3.png',
        'gradient': const [Color(0xFFE8C547), Color(0xFFD4A574)],
      },
      {
        'tier': 'PREMIUM',
        'desc': 'Elegant sedan for any occasion',
        'features': 'Comfort • Climate • Charger',
        'idx': 1,
        'accent': const Color(0xFFCECECE),
        'image': 'cruise_7.png',
        'gradient': const [Color(0xFFE8E8E8), Color(0xFFB0B0B0)],
      },
      {
        'tier': 'COMFORT',
        'desc': 'Reliable ride at great value',
        'features': 'Clean • Safe • Efficient',
        'idx': 2,
        'accent': const Color(0xFF4CAF50),
        'image': 'cruise_6.png',
        'gradient': const [Color(0xFF66BB6A), Color(0xFF388E3C)],
      },
    ];

    return Column(
      children: vehicles.map((v) {
        final accent = v['accent'] as Color;
        final idx = v['idx'] as int;
        final tier = v['tier'] as String;
        final gradient = v['gradient'] as List<Color>;
        final isVIP = tier == 'VIP';
        final isPremium = tier == 'PREMIUM';
        final isComfort = tier == 'COMFORT';

        // ── Animated tier badge (animation lives here, not on the card) ──
        final badgeAnim = isVIP
            ? _shimmerController
            : isPremium
                ? _promoShimmerCtrl
                : _clockRotateCtrl;

        final animatedBadge = AnimatedBuilder(
          animation: badgeAnim,
          builder: (_, __) {
            final t = badgeAnim.value;
            return Stack(
              alignment: Alignment.center,
              children: [
                // Base badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: gradient),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.45),
                        blurRadius: 14,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isVIP ? Icons.star_rounded : isPremium ? Icons.diamond_rounded : Icons.eco_rounded,
                        color: isVIP ? Colors.white : Colors.black87,
                        size: 12,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        tier,
                        style: TextStyle(
                          color: isVIP ? Colors.white : Colors.black87,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                // VIP: diagonal shimmer sweep across the badge
                if (isVIP)
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: IgnorePointer(
                        child: Transform.translate(
                          offset: Offset(160 * (t * 2.4 - 0.8), 0),
                          child: Transform.rotate(
                            angle: 0.4,
                            child: Container(
                              width: 28,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(colors: [
                                  Colors.transparent,
                                  Colors.white.withValues(alpha: 0.55),
                                  Colors.transparent,
                                ]),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // Premium: white flash pulse
                if (isPremium)
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: (() {
                            final d = (t - 0.5).abs();
                            return (1.0 - d * 5.5).clamp(0.0, 0.35);
                          })(),
                          child: Container(color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                // Comfort: green glow pulse
                if (isComfort)
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: (0.12 + 0.18 * math.sin(t * 2 * math.pi)).clamp(0.0, 0.35),
                          child: Container(color: accent),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );

        // ── Static card — no AnimatedBuilder wrapper ──
        // Map tier → ride option ID for pre-selection
        final rideId = isVIP ? 'suburban' : isPremium ? 'camry' : 'fusion';
        return Padding(
          padding: EdgeInsets.only(
            bottom: idx < 2 ? 16 : 0,
          ),
          child: IgnorePointer(
            ignoring: active,
            child: Opacity(
              opacity: active ? 0.45 : 1.0,
              child: GestureDetector(
                onTap: () => _openSearchThenRide(rideId: rideId),
                child: Container(
              constraints: const BoxConstraints(minHeight: 130),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: cardBg,
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: accent.withValues(alpha: 0.30),
                  width: isVIP ? 1.5 : 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                  BoxShadow(
                    color: accent.withValues(alpha: isVIP ? 0.15 : 0.08),
                    blurRadius: 36,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  // Ambient glow top-right (static)
                  Positioned(
                    right: -50, top: -30,
                    child: Container(
                      width: 200, height: 200,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(colors: [
                          accent.withValues(alpha: isVIP ? 0.18 : 0.09),
                          Colors.transparent,
                        ]),
                      ),
                    ),
                  ),
                  // Content row
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          flex: 5,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 16, 8, 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                animatedBadge,
                                const SizedBox(height: 10),
                                Text(
                                  v['desc'] as String,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.9),
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.3,
                                    height: 1.2,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  v['features'] as String,
                                  softWrap: true,
                                  style: TextStyle(
                                    color: accent.withValues(alpha: 0.85),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        SizedBox(
                          width: screenW * 0.38,
                          height: 130,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                            child: Image.asset(
                              'assets/images/${v['image']}',
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                              isAntiAlias: true,
                              alignment: Alignment.centerRight,
                              cacheWidth: 300,
                              errorBuilder: (ctx, err, st) => Icon(
                                Icons.directions_car_rounded,
                                color: accent.withValues(alpha: 0.5),
                                size: 50,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
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
                                child: const Text(
                                  'Retry',
                                  style: TextStyle(
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
                  _updateMiniMapAnnotation();
                },
                onStyleLoadedListener: (_) async {
                  if (_miniMapController != null) await _applyDarkNavyGoldTheme(_miniMapController!);
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
