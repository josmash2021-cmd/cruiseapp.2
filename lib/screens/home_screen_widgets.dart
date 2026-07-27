part of 'home_screen.dart';

// ════════════════════════════════════════════════════════════
//  WIDGETS — UI builders, panels, cards
// ════════════════════════════════════════════════════════════
// Neumorphic style lives in lib/widgets/neu_style.dart (shared), imported
// by home_screen.dart — use neuBase / neuBox here.

extension _HomeScreenWidgets on _HomeScreenState {

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
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: const Color(0xFF2A2A2A),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  title: Text(S.of(context).cancelRide, style: const TextStyle(color: Colors.white)),
                  content: Text(S.of(context).cancelRideConfirm, style: const TextStyle(color: Colors.white70)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: Text(S.of(context).cancelBtn, style: const TextStyle(color: Colors.white70)),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                      child: Text(S.of(context).confirm, style: const TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;
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

  // Draggable bottom sheet content. The sheet is permanently locked to
  // full screen, so the collapsed ↔ expanded crossfade is gone — everything
  // renders directly in its expanded state.
  Widget _buildSheet(ScrollController sc, double botPad) {
    final screenW = MediaQuery.of(context).size.width;
    final topPad = MediaQuery.of(context).padding.top;

    return Container(
      color: neuBase,
      child: CustomScrollView(
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
            // ── Top safe-area spacer (sheet is always full-screen) ──
            SizedBox(height: topPad),
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

            // ── Greeting row ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: RepaintBoundary(child: _buildTopBar()),
            ),
            const SizedBox(height: 24),

            // ── Hero CTA ("Where to?" / searching / "Ride in progress") ── ONE card only
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: RepaintBoundary(child: _buildHeroCTA()),
            ),

            // ── Scheduled ride indicator (below hero) — fades in/out ──
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: RepaintBoundary(child: _buildFleetStack(screenW)),
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

              const SizedBox(height: 36),

              // ── Your location (live mini map) ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: _buildSectionHeader(S.of(context).yourLocation, null, null),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: RepaintBoundary(child: _buildHomeMiniMapCard()),
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
          )),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════
  //  W I D G E T S
  // ════════════════════════════════════════════════════

  // ─── Top bar ───
  Widget _buildTopBar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textMain = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final displayName = [
      if (_firstName.isNotEmpty) _firstName,
      if (_lastName.isNotEmpty) _lastName,
    ].join(' ');

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
          semanticLabel: 'Notifications',
        ),
        const SizedBox(width: 12),

        // Settings
        _glassIconButton(
          Icons.settings_rounded,
          onTap: () async {
            await Navigator.of(
              context,
            ).push(slideFromRightRoute(const AccountScreen()));
            _loadSavedData();
          },
          semanticLabel: 'Settings',
        ),
      ],
    );
  }

  Widget _glassIconButton(IconData icon, {VoidCallback? onTap, int badge = 0, String? semanticLabel}) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: Responsive.w(44),
            height: Responsive.w(44),
            decoration: neuBox(radius: 22),
            child: Icon(
              icon,
              color: Colors.white.withValues(alpha: 0.4),
              size: Responsive.sp(22),
              semanticLabel: semanticLabel,
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

  // ─── Hero CTA Card — transforms between "Where to?" / searching / "Ride in progress" ───
  Widget _buildHeroCTA() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final active = _activeRide != null;
    final searching = _pendingSearchTripId != null && !active;
    final imminent = _hasImminentRide;
    final zoneBlocked = !_serviceZoneActive && _activeServiceStates.isNotEmpty;
    final verificationBlocked =
        !_isVerified && !active && _verificationResolved;
    final disabled = !active && !imminent && (zoneBlocked || verificationBlocked);
    return GestureDetector(
      onTap: () async {
        if (active) {
          _resumeActiveRide();
          return;
        }
        // Searching state: no navigation (same as the old floating bar) —
        // the cancel button inside the content handles its own tap.
        if (searching) return;
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
      child: Opacity(
        opacity: (disabled && !verificationBlocked) ? 0.55 : 1.0,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOutCubic,
          height: (active || imminent)
              ? Responsive.h(195)
              : searching
                  ? Responsive.h(80)
                  : verificationBlocked
                      ? Responsive.h(_verificationStatus == 'pending' ? 130 : 175)
                      : Responsive.h(155),
          decoration: neuBox(radius: 28),
          child: Container(
            padding: const EdgeInsets.all(24),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              switchInCurve: Curves.easeInOutCubic,
              switchOutCurve: Curves.easeInOutCubic,
              transitionBuilder: (child, anim) =>
                  FadeTransition(opacity: anim, child: child),
              child: active
                  ? _buildHeroRideInProgress()
                  : searching
                      ? _buildSearchingDriverContent()
                      : imminent
                          ? _buildHeroUpcomingRide()
                          : _buildHeroWhereToContent(isDark, disabled, zoneBlocked, verificationBlocked),
            ),
          ),
        ),
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
                _buildNowLaterSwitch(),
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
                fontSize: 12,
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
                fontSize: 12,
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
                fontSize: 12,
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
                fontSize: 12,
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
                child: Icon(Icons.electric_bolt_rounded, color: Colors.white, size: 26),
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
        // Calendar — modern icon with a soft gold gradient
        _animatedCircleAction(
          child: ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFFBE47A), Color(0xFFE8C547)],
            ).createShader(bounds),
            child: const Icon(
              Icons.calendar_month_rounded,
              color: Colors.white,
              size: 26,
            ),
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
                        Icons.percent_rounded,
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
                        Icons.percent_rounded,
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

  // ─── Now/Later segmented switch — pressed track + sliding gold thumb ───
  Widget _buildNowLaterSwitch() {
    const segW = 88.0;
    const segH = 34.0;

    Widget seg(String label, IconData icon, bool active, VoidCallback onTap) {
      return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: segW,
          height: segH,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 15,
                color: active
                    ? Colors.black
                    : Colors.white.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: active
                      ? Colors.black
                      : Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: neuBox(radius: 21, pressed: true),
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        width: segW * 2,
        height: segH,
        child: Stack(
          children: [
            // Sliding gold thumb
            AnimatedPositioned(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              left: _rideNow ? 0 : segW,
              top: 0,
              bottom: 0,
              width: segW,
              child: Container(
                decoration: BoxDecoration(
                  color: _gold,
                  borderRadius: BorderRadius.circular(segH / 2),
                  boxShadow: [
                    BoxShadow(
                      color: _gold.withValues(alpha: 0.35),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
              ),
            ),
            // Segments on top (labels stay tappable over the thumb)
            Row(
              children: [
                seg(S.of(context).nowLabel, Icons.bolt_rounded, _rideNow, () {
                  if (!_rideNow) _setState(() => _rideNow = true);
                }),
                seg(S.of(context).laterLabel, Icons.schedule_rounded,
                    !_rideNow, () {
                  if (_rideNow) {
                    _setState(() => _rideNow = false);
                    _showScheduleSheet();
                  }
                }),
              ],
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
            // Raised neumorphic circle with an inset well centering the icon
            Container(
              width: 64,
              height: 64,
              decoration: neuBox(radius: 32),
              child: Center(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: neuBox(radius: 22, pressed: true),
                  child: Center(child: child),
                ),
              ),
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

  // ─── "Your location" live mini map card ───
  // Follow-only map: gestures disabled so it never steals the sheet scroll.
  // When _activeRide != null this card isn't rendered (conditional block in
  // _buildSheet), so it costs nothing during a trip.
  Widget _buildHomeMiniMapCard() {
    // Mapbox Maps Flutter has no web implementation — its MapWidget crashes
    // during the first layout (bool.fromEnvironment non-const). On web show
    // a static placeholder instead of the live map.
    if (kIsWeb) {
      return Container(
        height: Responsive.h(190),
        decoration: neuBox(radius: 24),
        child: Center(
          child: Icon(
            Icons.map_outlined,
            color: _gold.withValues(alpha: 0.5),
            size: 40,
          ),
        ),
      );
    }

    // Default to NYC if no GPS yet — the camera recenters when the fix
    // arrives (throttled in the GPS stream listener).
    final pos = _currentLatLng ?? const LatLng(40.7128, -74.0060);

    return Container(
      height: Responsive.h(190),
      decoration: neuBox(radius: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: mapbox.MapWidget(
          key: const ValueKey('home_mini_map'),
          styleUri: MapboxConfig.styleDark,
          cameraOptions: mapbox.CameraOptions(
            center: mapbox.Point(
              coordinates: mapbox.Position(pos.longitude, pos.latitude),
            ),
            zoom: 15.0,
          ),
          // textureView works on more devices than surfaceView (default)
          textureView: true,
          onMapCreated: (ctrl) async {
            try {
              _homeMiniMapCtrl = ctrl;
              // The native view was just created — any previous annotation
              // belongs to an old manager. Reset so we create a fresh one.
              _homeDotAnnot = null;

              await ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
              await ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
              await ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
              await ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));
              // Follow-only: no gestures — the sheet scroll stays intact.
              await ctrl.gestures.updateSettings(mapbox.GesturesSettings(
                scrollEnabled: false,
                pinchToZoomEnabled: false,
                doubleTapToZoomInEnabled: false,
                doubleTouchToZoomOutEnabled: false,
                quickZoomEnabled: false,
                rotateEnabled: false,
                pitchEnabled: false,
              ));

              // Null the manager while creating so concurrent dot updates
              // return early instead of touching a stale manager.
              _homeDotAnnotMgr = null;
              try {
                _homeDotAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
              } catch (e) {
                if (kDebugMode) debugPrint('[HomeScreen] Mini map annotation manager failed: $e');
              }
              if (_homeDotAnnotMgr != null) {
                try {
                  await ctrl.style.setStyleLayerProperty(_homeDotAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
                  await ctrl.style.setStyleLayerProperty(_homeDotAnnotMgr!.id, 'icon-rotation-alignment', 'viewport');
                  await ctrl.style.setStyleLayerProperty(_homeDotAnnotMgr!.id, 'icon-allow-overlap', true);
                } catch (_) {}
              }

              // Native puck stays off — we draw the gold dot ourselves.
              await ctrl.location.updateSettings(mapbox.LocationComponentSettings(enabled: false));

              if (_currentLatLng != null) unawaited(_updateHomeDotAnnotation());
            } catch (e) {
              if (kDebugMode) debugPrint('[HomeScreen] Mini map onMapCreated error: $e');
            }
          },
          onStyleLoadedListener: (_) async {
            try {
              final ctrl = _homeMiniMapCtrl;
              if (ctrl == null) return;
              await MapTheme.applyNavyGold(ctrl);
              // Mapbox DESTROYS annotations + managers on style reload —
              // recreate them, then redraw the dot.
              _homeDotAnnot = null;
              _homeDotAnnotMgr = null;
              try {
                _homeDotAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
                await ctrl.style.setStyleLayerProperty(_homeDotAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
                await ctrl.style.setStyleLayerProperty(_homeDotAnnotMgr!.id, 'icon-rotation-alignment', 'viewport');
                await ctrl.style.setStyleLayerProperty(_homeDotAnnotMgr!.id, 'icon-allow-overlap', true);
              } catch (e) {
                if (kDebugMode) debugPrint('[HomeScreen] Mini map manager recreate failed: $e');
              }
              if (_currentLatLng != null) unawaited(_updateHomeDotAnnotation());
              // Re-disable native puck in case the style reset re-enabled it
              try {
                await ctrl.location.updateSettings(mapbox.LocationComponentSettings(enabled: false));
              } catch (_) {}
            } catch (e) {
              if (kDebugMode) debugPrint('[HomeScreen] Mini map onStyleLoaded error: $e');
            }
          },
          onMapLoadErrorListener: (err) {
            if (kDebugMode) debugPrint('[HomeScreen] Mini map load error: ${err.message} (type: ${err.type})');
          },
        ),
      ),
    );
  }

  // ─── Fleet header ───
  Widget _buildFleetHeader() {
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
          S.of(context).chooseRide,
          style: TextStyle(
            color: isDark ? Colors.white : const Color(0xFF1C1C1E),
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
      ],
    );
  }

  // ─── Fleet: Premium dark cards with gold particles ───
  Widget _buildFleetStack(double screenW) {
    final active = _activeRide != null;

    final s = S.of(context);
    final vehicles = [
      {
        'tier': 'VIP',
        'displayName': 'BLACK',
        'desc': s.vipDesc,
        'features': s.vipFeatures,
        'idx': 0,
        'image': 'cruisert1.png',
      },
      {
        'tier': 'PREMIUM',
        'displayName': 'PREMIUM',
        'desc': s.premiumDesc,
        'features': s.premiumFeatures,
        'idx': 1,
        'image': 'cruisert2.png',
      },
      {
        'tier': 'COMFORT',
        'displayName': 'STANDARD',
        'desc': s.comfortDesc,
        'features': s.comfortFeatures,
        'idx': 2,
        'image': 'cruisert3.png',
      },
    ];

    return Row(
      children: vehicles.map((v) {
        final idx = v['idx'] as int;
        final tier = v['tier'] as String;
        final displayName = v['displayName'] as String;
        final isVIP = tier == 'VIP';

        final rideId = isVIP ? 'suburban' : tier == 'PREMIUM' ? 'camry' : 'fusion';

        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: idx < 2 ? 8 : 0),
            child: IgnorePointer(
              ignoring: active,
              child: Opacity(
                opacity: active ? 0.45 : 1.0,
                child: GestureDetector(
                  onTap: () => _openSearchThenRide(rideId: rideId),
                  child: Container(
                    height: 152,
                    clipBehavior: Clip.antiAlias,
                    // Selected tier (PREMIUM) gets a thin gold border on top
                    // of the neumorphic surface.
                    decoration: tier == 'PREMIUM'
                        ? neuBox(radius: 24).copyWith(
                            border: Border.all(
                              color: _gold.withValues(alpha: 0.45),
                              width: 1,
                            ),
                          )
                        : neuBox(radius: 24),
                    child: Stack(
                      children: [
                        // Display name pinned to the top
                        Positioned(
                          top: 12,
                          left: 8,
                          right: 8,
                          child: Text(
                            displayName,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        // Car image centered inside the card with breathing
                        // room on the sides and a gap above the bottom edge.
                        Positioned(
                          left: 16,
                          right: 16,
                          bottom: 16,
                          child: SizedBox(
                            height: 58,
                            child: CarImage3D(
                              assetPath: 'assets/images/${v['image']}',
                              cacheWidth: 640,
                              alignment: Alignment.bottomCenter,
                              fallback: Icon(
                                Icons.directions_car_rounded,
                                color: _gold.withValues(alpha: 0.5),
                                size: 40,
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
                  decoration: neuBox(radius: 16),
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
                                fontSize: 12,
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
        decoration: neuBox(radius: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icon inside a pressed neumorphic well, tinted with the
            // tile's accent color.
            Container(
              width: 40,
              height: 40,
              decoration: neuBox(radius: 14, pressed: true),
              child: Icon(icon, color: accent, size: 20),
            ),
            const SizedBox(height: 10),
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
                fontSize: 12,
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
                    decoration: neuBox(radius: 18),
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

  // ─── Scheduled ride indicator ───
  /// Formats a scheduled-ride date without intl. The project never calls
  /// initializeDateFormatting, so DateFormat(pattern, 'es') throws a
  /// LocaleDataException — this local month table works in both languages.
  String _formatRideDate(DateTime dt, bool isEs) {
    const monthsEn = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const monthsEs = ['ene','feb','mar','abr','may','jun','jul','ago','sep','oct','nov','dic'];
    final m = isEs ? monthsEs[dt.month - 1] : monthsEn[dt.month - 1];
    final h12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final mm = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return isEs ? '${dt.day} de $m, $h12:$mm $ampm' : '$m ${dt.day}, $h12:$mm $ampm';
  }

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
    final dateStr = dt != null ? _formatRideDate(dt.toLocal(), isEs) : '';

    final accent = hasDriver ? const Color(0xFF4CAF50) : _gold;

    return GestureDetector(
      onTap: () async {
        await _openScheduledRideLive();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        // Soft neumorphic surface; the green/gold accent stays on the
        // border, icon and label.
        decoration: neuBox(radius: 14).copyWith(
          border: Border.all(color: accent.withValues(alpha: 0.25), width: 1),
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
    final s = S.of(context);
    final items = [
      (icon: Icons.explore_rounded, label: s.rideLabel),
      (icon: Icons.calendar_today_rounded, label: s.schedule),
      (icon: Icons.person_rounded, label: s.accountLabel),
    ];

    return Container(
      margin: EdgeInsets.fromLTRB(40, 0, 40, bottomPad + 16),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: neuBox(radius: 28),
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
