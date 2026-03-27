part of 'ride_request_screen.dart';

// ════════════════════════════════════════════════════════════
//  WIDGETS — panels, cards, overlays
// ════════════════════════════════════════════════════════════

extension RideRequestWidgets on _RideRequestScreenState {

  // ── "Where to?" bar ──

  String get _rideBadgeLabel {
    if (widget.isAirportTrip) return S.of(context).airportLabel;
    if (widget.scheduledAt != null) return S.of(context).scheduleLabel;
    return S.of(context).nowLabel;
  }

  IconData get _rideBadgeIcon {
    if (widget.isAirportTrip) return Icons.flight_takeoff_rounded;
    if (widget.scheduledAt != null) return Icons.schedule_rounded;
    return Icons.access_time_rounded;
  }

  Widget _buildWhereToBar(AppColors c, double topPad, bool visible) {
    return Positioned(
      top: topPad + 12,
      left: 16,
      right: 16,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        offset: visible ? Offset.zero : const Offset(0, -1.5),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: visible ? 1.0 : 0.0,
          child: IgnorePointer(
            ignoring: !visible,
            child: Row(
              children: [
                // ── Back arrow ──
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1A),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          blurRadius: 12,
                          offset: const Offset(0, 3),
                        ),
                      ],
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.06),
                      ),
                    ),
                    child: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // ── Search pill ──
                Expanded(
                  child: GestureDetector(
                    onTap: _openSearch,
                    child: Container(
                      height: 52,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A1A),
                        borderRadius: BorderRadius.circular(26),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.06),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 16),
                          Icon(Icons.search_rounded, color: c.gold, size: 22),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              S.of(context).whereToQuestion,
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: Colors.white.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                          // Dynamic badge: Now / Schedule / Airport
                          Container(
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: c.gold.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(_rideBadgeIcon, color: c.gold, size: 16),
                                const SizedBox(width: 4),
                                Text(
                                  _rideBadgeLabel,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: c.gold,
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
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Route preview sheet ──

  Widget _buildRoutePreviewSheet(AppColors c, double bottomPad) {
    final s = _ctrl.state;

    // Fast ride: show only one "Comfort" option with express pricing (~$2.67/min ≈ $160/hr)
    List<RideOption> displayOptions = s.rideOptions;
    if (widget.fastRide && s.rideOptions.isNotEmpty) {
      final baseFusion = s.rideOptions.last; // Fusion = cheapest = base
      final expressPrice = (baseFusion.priceEstimate * 3.2)
          .roundToDouble(); // ~$160/hr rate
      displayOptions = [
        RideOption(
          id: 'comfort_express',
          name: 'Comfort',
          description: 'Express pickup · Premium',
          priceEstimate: expressPrice,
          etaMinutes: 2 + (baseFusion.etaMinutes ~/ 3),
          icon: '⚡',
          capacity: 4,
        ),
      ];
    }

    // Apply 10% promo discount
    if (widget.applyPromo) {
      displayOptions = displayOptions
          .map(
            (o) => RideOption(
              id: o.id,
              name: o.name,
              description: o.description,
              priceEstimate:
                  (o.priceEstimate * 0.9 * 100).roundToDouble() / 100,
              etaMinutes: o.etaMinutes,
              icon: o.icon,
              capacity: o.capacity,
            ),
          )
          .toList();
    }

    final option = widget.fastRide
        ? (displayOptions.isNotEmpty ? displayOptions.first : s.selectedOption)
        : s.selectedOption;
    final screenH = MediaQuery.of(context).size.height;
    final sheetH = (screenH * 0.45).clamp(320.0, 420.0) + bottomPad;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: AnimatedBuilder(
        animation: _sheetCtrl,
        builder: (context, child) {
          return Transform.translate(
            offset: Offset(0, _sheetSlide.value * sheetH),
            child: child,
          );
        },
        child: Container(
          constraints: BoxConstraints(maxHeight: sheetH),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 20,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Drag handle
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Title — tappable to collapse/expand
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: GestureDetector(
                      onTap: () => setState(
                        () => _rideOptionsExpanded = !_rideOptionsExpanded,
                      ),
                      behavior: HitTestBehavior.opaque,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Spacer(),
                          Text(
                            widget.fastRide
                                ? S.of(context).fastRideLabel
                                : S.of(context).chooseARide,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: Colors.white.withValues(alpha: 0.9),
                              letterSpacing: -0.3,
                            ),
                          ),
                          if (_ctrl.state.isAirportTrip) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF4285F4,
                                ).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.flight_rounded,
                                    size: 12,
                                    color: Color(0xFF4285F4),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    S.of(context).airportLabel,
                                    style: TextStyle(
                                      color: Color(0xFF4285F4),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          if (widget.applyPromo) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFFE8C547,
                                ).withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                '10% OFF',
                                style: TextStyle(
                                  color: Color(0xFFE8C547),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                          const Spacer(),
                          if (!widget.fastRide)
                            AnimatedRotation(
                              turns: _rideOptionsExpanded ? 0.0 : -0.25,
                              duration: const Duration(milliseconds: 250),
                              curve: Curves.easeInOut,
                              child: Icon(
                                Icons.keyboard_arrow_down_rounded,
                                color: Colors.white.withValues(alpha: 0.5),
                                size: 22,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Ride options list — collapsible
                  AnimatedCrossFade(
                    firstChild: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Route failed → show retry
                          if (_ctrl.state.routeFetchFailed && displayOptions.isEmpty)
                            _buildRouteFailedRetry()
                          // Loading → shimmer placeholders
                          else if (displayOptions.isEmpty)
                            for (int i = 0; i < 3; i++) ...[
                              _buildShimmerCard(),
                              if (i < 2) const SizedBox(height: 6),
                            ]
                          // Real options — staggered slide-up entrance
                          else
                            for (int i = 0; i < displayOptions.length; i++) ...[
                              TweenAnimationBuilder<double>(
                                key: ValueKey('ride_opt_${displayOptions[i].id}'),
                                tween: Tween(begin: 0.0, end: 1.0),
                                duration: const Duration(milliseconds: 350),
                                curve: Curves.easeOutCubic,
                                builder: (context, val, child) {
                                  // Stagger: each card waits 80ms * index
                                  final delay = i * 0.15; // 0.15 of total duration per card
                                  final progress = ((val - delay) / (1.0 - delay)).clamp(0.0, 1.0);
                                  return Transform.translate(
                                    offset: Offset(0, 20 * (1.0 - progress)),
                                    child: Opacity(
                                      opacity: progress,
                                      child: child,
                                    ),
                                  );
                                },
                                child: GestureDetector(
                                  onTap: () {
                                    _ctrl.selectRideOption(displayOptions[i]);
                                    // Auto-collapse immediately after selecting
                                    setState(
                                      () => _rideOptionsExpanded = false,
                                    );
                                    // Single gentle 15° tilt — only once
                                    if (!_hasAppliedSelectionTilt && _mapCtrl != null) {
                                      _hasAppliedSelectionTilt = true;
                                      _mapCtrl!.flyTo(
                                        mapbox.CameraOptions(pitch: 15.0),
                                        mapbox.MapAnimationOptions(duration: 800),
                                      );
                                    }
                                  },
                                  child: _buildRideOptionCard(
                                    c,
                                    displayOptions[i],
                                    option?.id == displayOptions[i].id,
                                  ),
                                ),
                              ),
                              if (i < displayOptions.length - 1)
                                const SizedBox(height: 6),
                            ],
                        ],
                      ),
                    ),
                    secondChild: option != null
                        ? GestureDetector(
                            onTap: () =>
                                setState(() => _rideOptionsExpanded = true),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: _buildRideOptionCard(c, option, true),
                            ),
                          )
                        : const SizedBox.shrink(),
                    crossFadeState: _rideOptionsExpanded
                        ? CrossFadeState.showFirst
                        : CrossFadeState.showSecond,
                    duration: const Duration(milliseconds: 300),
                    sizeCurve: Curves.easeInOutCubic,
                  ),

                  const SizedBox(height: 6),
                  Divider(
                    height: 1,
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                  const SizedBox(height: 6),

                  // Payment Method + Request Ride buttons — hidden during shimmer, fade in when ready
                  AnimatedOpacity(
                    opacity: _optionsLoaded ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                      child: _optionsLoaded
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Payment Method — dark gray fill
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20),
                                  child: GestureDetector(
                                    onTap: () => _showPaymentMethodPicker(c, option),
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
                                ),
                                const SizedBox(height: 10),

                                // Request Ride button — flat 2D, gold border
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20),
                                  child: AnimatedBuilder(
                                    animation: _shakeAnim,
                                    builder: (_, child) => Transform.translate(
                                      offset: Offset(_shakeAnim.value, 0),
                                      child: child,
                                    ),
                                    child: GestureDetector(
                                      onTap: option != null && !_isProcessingPayment
                                          ? () => _startRideDirectly(c, option)
                                          : option == null && !_isProcessingPayment
                                              ? () => _shakeCtrl.forward(from: 0)
                                              : null,
                                      child: Container(
                                        width: double.infinity,
                                        height: 56,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF0D0D0D),
                                          borderRadius: BorderRadius.circular(14),
                                          border: Border.all(
                                            color: option != null
                                                ? const Color(0xFFFFD700)
                                                : const Color(0xFFFFD700).withValues(alpha: 0.3),
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
                                                  children: [
                                                    _buildPaymentLogo(),
                                                    const SizedBox(width: 8),
                                                    Expanded(
                                                      child: AnimatedSwitcher(
                                                        duration: const Duration(milliseconds: 300),
                                                        child: Text(
                                                          option != null
                                                              ? 'Pay · \$${option.priceEstimate.toStringAsFixed(2)}'
                                                              : S.of(context).pickYourOption,
                                                          key: ValueKey(option?.id),
                                                          maxLines: 1,
                                                          overflow: TextOverflow.ellipsis,
                                                          style: TextStyle(
                                                            color: option != null
                                                                ? Colors.white
                                                                : Colors.white38,
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
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  int _parseDurationMins(String text) {
    final parts = text.split(RegExp(r'\s+'));
    int total = 0;
    for (int i = 0; i < parts.length; i++) {
      final n = int.tryParse(parts[i]);
      if (n != null && i + 1 < parts.length) {
        if (parts[i + 1].startsWith('h')) {
          total += n * 60;
        } else {
          total += n;
        }
      }
    }
    return total > 0 ? total : 10;
  }

  String _carAssetForOption(String name) {
    final key = name.trim().toLowerCase();
    if (key.contains('vip') || key.contains('suburban')) return 'assets/images/cruise_3.png';
    if (key.contains('sedan') || key.contains('camry')) return 'assets/images/cruise_7.png';
    return 'assets/images/cruise_6.png';
  }

  Widget _buildRideOptionCard(AppColors c, RideOption opt, bool selected) {
    final isSuv = opt.id == 'suburban';
    final isFusion = opt.id == 'fusion';

    // Tier styling — match home_screen badge colors exactly
    final bool isVIP = isSuv;
    final bool isPremium = !isSuv && !isFusion;
    final bool isComfort = isFusion;
    final String tierLabel = isVIP ? 'VIP' : isPremium ? 'PREMIUM' : 'COMFORT';
    final List<Color> gradient = isVIP
        ? const [Color(0xFFE8C547), Color(0xFFD4A574)]
        : isPremium
            ? const [Color(0xFFE8E8E8), Color(0xFFB0B0B0)]
            : const [Color(0xFF66BB6A), Color(0xFF388E3C)];
    final Color accent = gradient[0];
    final IconData tierIcon = isVIP
        ? Icons.star_rounded
        : isPremium
            ? Icons.diamond_rounded
            : Icons.eco_rounded;
    final Color tierTextColor = isVIP ? Colors.white : Colors.black87;
    final AnimationController badgeAnim = isVIP
        ? _shimmerCtrl
        : isPremium
            ? _badgePremiumCtrl
            : _badgeComfortCtrl;

    return AnimatedScale(
      scale: selected ? 1.0 : 0.97,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutBack,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: selected
            ? Colors.white.withValues(alpha: 0.08)
            : const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected
              ? _cardGold.withValues(alpha: 0.55)
              : Colors.white.withValues(alpha: 0.06),
          width: selected ? 1.5 : 1.0,
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: _cardGold.withValues(alpha: 0.15),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ]
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.20),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: Row(
        children: [
          // Car image — HD crisp rendering
          SizedBox(
            width: 108,
            height: 72,
            child: Image.asset(
              _carAssetForOption(opt.name),
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
              isAntiAlias: true,
              alignment: Alignment.center,
              cacheWidth: 216,
              errorBuilder: (_, e, s) => Icon(
                Icons.directions_car_rounded,
                size: 36,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(width: 10),

          // Info column
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Tier badge — animated gradient pill (matches home_screen)
                AnimatedBuilder(
                  animation: badgeAnim,
                  builder: (_, __) {
                    final t = badgeAnim.value;
                    return Stack(
                      alignment: Alignment.center,
                      children: [
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
                              Icon(tierIcon, color: tierTextColor, size: 12),
                              const SizedBox(width: 5),
                              Text(
                                tierLabel,
                                style: TextStyle(
                                  color: tierTextColor,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // VIP: diagonal shimmer sweep
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
                ),
                const SizedBox(height: 2),
                // Description
                Text(
                  opt.description,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.45),
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 4),
                // Trip time + arrival time
                Builder(
                  builder: (_) {
                    final routeMins = _ctrl.state.route != null
                        ? _parseDurationMins(_ctrl.state.route!.durationText)
                        : 0;
                    final arrival = DateTime.now().add(
                      Duration(minutes: opt.etaMinutes + routeMins),
                    );
                    final h = arrival.hour;
                    final m = arrival.minute;
                    final ampm = h >= 12 ? 'PM' : 'AM';
                    final h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
                    final arrivalStr =
                        '$h12:${m.toString().padLeft(2, '0')} $ampm';
                    return Row(
                      children: [
                        _chipWidget(
                          Icons.schedule_rounded,
                          '${opt.etaMinutes} min',
                        ),
                        const SizedBox(width: 6),
                        _chipWidget(
                          Icons.access_time_filled_rounded,
                          arrivalStr,
                        ),
                        const SizedBox(width: 6),
                        _chipWidget(Icons.person_rounded, '${opt.capacity}'),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),

          // Price column
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (_ctrl.state.route == null || _ctrl.state.rideOptions.isEmpty)
                _buildPriceShimmer(width: 54, height: 18)
              else
                Text(
                  '\$${opt.priceEstimate.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: selected ? _cardGold : Colors.white,
                    letterSpacing: -0.3,
                  ),
                ),
              const SizedBox(height: 2),
              Text(
                'est. fare',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.white.withValues(alpha: 0.35),
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (selected) ...[
                const SizedBox(height: 6),
                Container(
                  width: 20,
                  height: 20,
                  decoration: const BoxDecoration(
                    color: _cardGold,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 14,
                    color: Colors.white,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    ),   // ← closes AnimatedContainer
    );   // ← closes AnimatedScale
  }

  Widget _chipWidget(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white.withValues(alpha: 0.40)),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.50),
            ),
          ),
        ],
      ),
    );
  }

  /// Animated shimmer placeholder for price while loading.
  Widget _buildPriceShimmer({required double width, required double height}) {
    return AnimatedBuilder(
      animation: _priceShimmerCtrl,
      builder: (context, _) {
        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            gradient: LinearGradient(
              begin: Alignment(-1.0 + 2.0 * _priceShimmerCtrl.value, 0),
              end: Alignment(1.0 + 2.0 * _priceShimmerCtrl.value, 0),
              colors: const [
                Color(0xFF2A2A2A),
                Color(0xFF3A3A3A),
                Color(0xFF2A2A2A),
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
        );
      },
    );
  }

  /// Shimmer placeholder card mimicking a ride option while loading.
  Widget _buildShimmerCard() {
    return AnimatedBuilder(
      animation: _priceShimmerCtrl,
      builder: (context, _) {
        final gradient = LinearGradient(
          begin: Alignment(-1.0 + 2.0 * _priceShimmerCtrl.value, 0),
          end: Alignment(1.0 + 2.0 * _priceShimmerCtrl.value, 0),
          colors: const [
            Color(0xFF2A2A2A),
            Color(0xFF3A3A3A),
            Color(0xFF2A2A2A),
          ],
          stops: const [0.0, 0.5, 1.0],
        );
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
          ),
          child: Row(
            children: [
              // Icon placeholder
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: gradient,
                ),
              ),
              const SizedBox(width: 10),
              // Text placeholders
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(width: 80, height: 14, decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), gradient: gradient)),
                    const SizedBox(height: 6),
                    Container(width: 120, height: 10, decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), gradient: gradient)),
                    const SizedBox(height: 6),
                    Container(width: 100, height: 10, decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), gradient: gradient)),
                  ],
                ),
              ),
              // Price placeholder
              Container(width: 54, height: 18, decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), gradient: gradient)),
            ],
          ),
        );
      },
    );
  }

  /// "Could not load route" card with retry button.
  Widget _buildRouteFailedRetry() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        children: [
          Text(
            'Could not load route',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () {
              setState(() {});
              _ctrl.retryFetchRoute();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE8C547)),
              ),
              child: const Text(
                'Tap to retry',
                style: TextStyle(
                  color: Color(0xFFE8C547),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocationInfo(IconData icon, String text, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: 0.8),
            ),
          ),
        ),
      ],
    );
  }

  // ── Premium "Looking for ride" bottom card ──

  Widget _buildSearchingBottomCard(AppColors c) {
    final s = _ctrl.state;
    final statusMsg = _searchStatusMessages[
        _searchStatusIdx % _searchStatusMessages.length];
    final pickupText = s.pickupLabel.isNotEmpty
        ? s.pickupLabel
        : S.of(context).currentLocation;
    final dropoffText = s.dropoffLabel.isNotEmpty
        ? _truncateHalf(s.dropoffLabel)
        : S.of(context).destination;

    return Positioned(
      left: 16,
      right: 16,
      bottom: 24,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        offset: _searchingShowMap ? Offset.zero : const Offset(0, 1.2),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 320),
          opacity: _searchingShowMap ? 1.0 : 0.0,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              // 3D fade shadow — layered for depth
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.65),
                  blurRadius: 40,
                  spreadRadius: 4,
                  offset: const Offset(0, 12),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.30),
                  blurRadius: 16,
                  spreadRadius: 0,
                  offset: const Offset(0, 4),
                ),
                BoxShadow(
                  color: const Color(0xFFE8C547).withValues(alpha: 0.06),
                  blurRadius: 48,
                  spreadRadius: 0,
                  offset: Offset.zero,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Container(
                decoration: const BoxDecoration(
                  color: Color(0xFF0F0F14),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // ── Drag handle ──
                      Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                        const SizedBox(height: 20),

                        // ── Radar animation + car + route info row ──
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // Radar pulse stack
                            SizedBox(
                              width: 80,
                              height: 80,
                              child: AnimatedBuilder(
                                animation: _radarCtrl,
                                builder: (context, _) {
                                  return Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      // 3 expanding rings
                                      ...List.generate(3, (i) {
                                        final offset = i / 3.0;
                                        final t = (_radarCtrl.value + offset) % 1.0;
                                        final size = 28.0 + t * 60.0;
                                        final alpha = (1.0 - t) * 0.45;
                                        return Container(
                                          width: size,
                                          height: size,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: const Color(0xFFE8C547)
                                                  .withValues(alpha: alpha),
                                              width: 1.5,
                                            ),
                                          ),
                                        );
                                      }),
                                      // Gold glow core
                                      Container(
                                        width: 50,
                                        height: 50,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          gradient: RadialGradient(
                                            colors: [
                                              const Color(0xFFE8C547)
                                                  .withValues(alpha: 0.25),
                                              const Color(0xFFE8C547)
                                                  .withValues(alpha: 0.0),
                                            ],
                                          ),
                                        ),
                                      ),
                                      // Car icon circle
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF1C1C24),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: const Color(0xFFE8C547)
                                                .withValues(alpha: 0.55),
                                            width: 1.5,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: const Color(0xFFE8C547)
                                                  .withValues(alpha: 0.30),
                                              blurRadius: 16,
                                              spreadRadius: 2,
                                            ),
                                          ],
                                        ),
                                        child: const Icon(
                                          Icons.local_taxi_rounded,
                                          color: Color(0xFFE8C547),
                                          size: 20,
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 18),

                            // ── Status + route ──
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Animated status message
                                  AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 280),
                                    transitionBuilder: (child, anim) =>
                                        FadeTransition(
                                      opacity: CurvedAnimation(
                                        parent: anim,
                                        curve: Curves.easeInOut,
                                      ),
                                      child: child,
                                    ),
                                    child: Text(
                                      statusMsg,
                                      key: ValueKey(statusMsg),
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                        letterSpacing: -0.2,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),

                                  // Route pill
                                  Row(
                                    children: [
                                      Container(
                                        width: 6,
                                        height: 6,
                                        decoration: const BoxDecoration(
                                          color: Color(0xFF4ADE80),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          pickupText,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.white
                                                .withValues(alpha: 0.50),
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 5),
                                        child: Icon(
                                          Icons.arrow_forward_rounded,
                                          size: 11,
                                          color: Colors.white
                                              .withValues(alpha: 0.30),
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          dropoffText,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.white
                                                .withValues(alpha: 0.50),
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 20),

                        // ── Shimmer progress bar ──
                        AnimatedBuilder(
                          animation: _shimmerCtrl,
                          builder: (context, _) {
                            return Container(
                              height: 3,
                              decoration: BoxDecoration(
                                color:
                                    Colors.white.withValues(alpha: 0.07),
                                borderRadius: BorderRadius.circular(2),
                              ),
                              child: FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor: 1.0,
                                child: ShaderMask(
                                  shaderCallback: (bounds) =>
                                      LinearGradient(
                                    begin: Alignment.centerLeft,
                                    end: Alignment.centerRight,
                                    stops: [
                                      (_shimmerCtrl.value - 0.3)
                                          .clamp(0.0, 1.0),
                                      _shimmerCtrl.value.clamp(0.0, 1.0),
                                      (_shimmerCtrl.value + 0.3)
                                          .clamp(0.0, 1.0),
                                    ],
                                    colors: const [
                                      Color(0xFFE8C547),
                                      Colors.white,
                                      Color(0xFFE8C547),
                                    ],
                                  ).createShader(bounds),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFE8C547),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),

                        const SizedBox(height: 20),

                        // ── Cancel button ──
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: TextButton(
                            onPressed: _confirmCancelSearching,
                            style: TextButton.styleFrom(
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.06),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.10),
                                ),
                              ),
                            ),
                            child: Text(
                              S.of(context).cancel,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Colors.white60,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                      ],
                    ),
                  ),
                ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Payment logo for Request Ride button ──

  Widget _buildPaymentLogo() {
    switch (_selectedPaymentMethod) {
      case 'apple_pay':
        return const Icon(Icons.apple, color: Colors.white, size: 22);
      case 'google_pay':
        return RichText(
          text: const TextSpan(
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            children: [
              TextSpan(text: 'G', style: TextStyle(color: Color(0xFF4285F4))),
            ],
          ),
        );
      case 'paypal':
        return const Text(
          'P',
          style: TextStyle(
            color: Color(0xFF003087),
            fontSize: 18,
            fontWeight: FontWeight.w800,
            fontStyle: FontStyle.italic,
          ),
        );
      case 'credit_card':
        return const Text('\u{1F4B3}', style: TextStyle(fontSize: 18));
      default:
        return const Icon(
          Icons.payment_rounded,
          color: Colors.white38,
          size: 22,
        );
    }
  }

  Widget _paymentLogoWidget(String id, double size) {
    switch (id) {
      case 'apple_pay':
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(
            child: Icon(Icons.apple, color: Colors.white, size: size * 0.55),
          ),
        );
      case 'google_pay':
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade300, width: 0.5),
          ),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Image.asset(
              'assets/images/google_g.png',
              fit: BoxFit.contain,
              cacheWidth: 80,
            ),
          ),
        );
      case 'paypal':
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade300, width: 0.5),
          ),
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Image.asset(
              'assets/images/paypal_logo.png',
              fit: BoxFit.contain,
              cacheWidth: 80,
            ),
          ),
        );
      case 'credit_card':
        if (_savedCardBrand != null && _savedCardBrand != 'visa') {
          final Map<String, ({String letter, Color color, bool italic})>
          brands = {
            'mastercard': (
              letter: 'M',
              color: const Color(0xFFEB001B),
              italic: false,
            ),
            'amex': (
              letter: 'A',
              color: const Color(0xFF006FCF),
              italic: false,
            ),
            'discover': (
              letter: 'D',
              color: const Color(0xFFFF6000),
              italic: false,
            ),
          };
          final info = brands[_savedCardBrand];
          if (info != null) {
            return Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade300, width: 0.5),
              ),
              child: Center(
                child: Text(
                  info.letter,
                  style: TextStyle(
                    color: info.color,
                    fontSize: size * 0.56,
                    fontWeight: FontWeight.w900,
                    fontStyle: info.italic
                        ? FontStyle.italic
                        : FontStyle.normal,
                    fontFamily: 'Roboto',
                  ),
                ),
              ),
            );
          }
        }
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: const Color(0xFF6B7280).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Center(
            child: Icon(
              Icons.credit_card_rounded,
              color: Color(0xFF6B7280),
              size: 20,
            ),
          ),
        );
      default:
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: const Color(0xFF6B7280).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Center(
            child: Icon(
              Icons.payment_rounded,
              color: Color(0xFF6B7280),
              size: 20,
            ),
          ),
        );
    }
  }

  /// Official Apple Pay / Google Pay wide logo button (no extra text).
  Widget _nativePayLogoWide(String id) {
    if (id == 'apple_pay') {
      return Container(
        height: 44,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        ),
        child: const Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.apple, color: Colors.white, size: 28),
              SizedBox(width: 6),
              Text('Apple Pay', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w500, letterSpacing: -0.3)),
            ],
          ),
        ),
      );
    }
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Center(
        child: RichText(
          text: const TextSpan(
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            children: [
              TextSpan(text: 'G', style: TextStyle(color: Color(0xFF4285F4))),
              TextSpan(text: 'o', style: TextStyle(color: Color(0xFFEA4335))),
              TextSpan(text: 'o', style: TextStyle(color: Color(0xFFFBBC05))),
              TextSpan(text: 'g', style: TextStyle(color: Color(0xFF4285F4))),
              TextSpan(text: 'le ', style: TextStyle(color: Color(0xFF34A853))),
              TextSpan(text: 'Pay', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDriverFoundOverlay(AppColors c) {
    final driver = _ctrl.state.driver!;
    final firstName = driver.name.split(' ').first;
    const gold = Color(0xFFD4AF37);
    const cardBg = Color(0xFF1A1A1A);
    final stagger = _dfStaggerCtrl;
    final checkCtrl = _dfCheckCtrl;
    final shimmer = _dfShimmerCtrl;
    if (stagger == null || checkCtrl == null || shimmer == null) {
      return const SizedBox.shrink();
    }

    final messages = [
      '${driver.vehicleColor} ${driver.vehicleMake} ${driver.vehicleModel}',
      '⭐ ${driver.rating.toStringAsFixed(1)} · ${driver.vehiclePlate}',
      '$firstName ${S.of(context).isOnTheWay}',
    ];

    final pickup = _ctrl.state.pickup;
    final dropoff = _ctrl.state.dropoff;
    final midLat = (pickup != null && dropoff != null)
        ? (pickup.lat + dropoff.lat) / 2
        : pickup?.lat ?? 0;
    final midLng = (pickup != null && dropoff != null)
        ? (pickup.lng + dropoff.lng) / 2
        : pickup?.lng ?? 0;
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: AnimatedOpacity(
          opacity: _driverFoundVisible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 400),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // ── Full-screen Mapbox map background with tilt + route + pins ──
              if (pickup != null)
                IgnorePointer(
                  child: RepaintBoundary(
                    child: mapbox.MapWidget(
                      styleUri: MapboxConfig.styleDark,
                      cameraOptions: mapbox.CameraOptions(
                        center: mapbox.Point(
                          coordinates: mapbox.Position(midLng, midLat),
                        ),
                        zoom: 14.5,
                        pitch: 0.0,
                      ),
                      onMapCreated: (ctrl) async {
                        _dfMapCtrl = ctrl;
                        await MapTheme.applyNavyGold(ctrl);
                        ctrl.scaleBar.updateSettings(
                            mapbox.ScaleBarSettings(enabled: false));
                        ctrl.compass.updateSettings(
                            mapbox.CompassSettings(enabled: false));
                        ctrl.attribution.updateSettings(
                            mapbox.AttributionSettings(enabled: false));
                        ctrl.logo.updateSettings(
                            mapbox.LogoSettings(enabled: false));

                        // Animate tilt 0° → 20°
                        if (_dfTiltAnim != null && _dfTiltCtrl != null) {
                          _dfTiltAnim!.addListener(() {
                            _dfMapCtrl?.setCamera(
                              mapbox.CameraOptions(pitch: _dfTiltAnim!.value),
                            );
                          });
                          _dfTiltCtrl!.forward();
                        }

                        // Add route polyline
                        final routePts = _ctrl.state.route?.points;
                        if (routePts != null && routePts.length >= 2) {
                          final polyMgr = await ctrl.annotations
                              .createPolylineAnnotationManager();
                          final coords = routePts
                              .map((p) =>
                                  mapbox.Position(p.longitude, p.latitude))
                              .toList();
                          await polyMgr.create(mapbox.PolylineAnnotationOptions(
                            geometry:
                                mapbox.LineString(coordinates: coords),
                            lineColor: const Color(0xFFFFD700).toARGB32(),
                            lineWidth: 5.0,
                            lineJoin: mapbox.LineJoin.ROUND,
                          ));
                        }

                        // Add smart pins (pickup + dropoff)
                        final pointMgr = await ctrl.annotations
                            .createPointAnnotationManager();
                        final pickupBytes =
                            await GoldPinRenderer.render(isPickup: true);
                        await pointMgr.create(mapbox.PointAnnotationOptions(
                          geometry: mapbox.Point(
                            coordinates:
                                mapbox.Position(pickup.lng, pickup.lat),
                          ),
                          image: pickupBytes,
                          iconSize: 0.5,
                          iconAnchor: mapbox.IconAnchor.BOTTOM,
                        ));
                        if (dropoff != null) {
                          final dropoffBytes =
                              await GoldPinRenderer.render(isPickup: false);
                          await pointMgr.create(mapbox.PointAnnotationOptions(
                            geometry: mapbox.Point(
                              coordinates:
                                  mapbox.Position(dropoff.lng, dropoff.lat),
                            ),
                            image: dropoffBytes,
                            iconSize: 0.5,
                            iconAnchor: mapbox.IconAnchor.BOTTOM,
                          ));
                        }
                      },
                    ),
                  ),
                )
              else
                const ColoredBox(color: Color(0xFF0A0A1A)),
              // ── Subtle gradient overlay (let map show through, like Trip Accepted) ──
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.15),
                        Colors.black.withValues(alpha: 0.55),
                        Colors.black.withValues(alpha: 0.85),
                      ],
                      stops: const [0.0, 0.5, 1.0],
                    ),
                  ),
                ),
              ),
              // ── Content (positioned at bottom like Trip Accepted) ──
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.3),
                    end: Offset.zero,
                  ).animate(CurvedAnimation(
                    parent: stagger,
                    curve: const Interval(0.0, 0.4, curve: Curves.easeOutCubic),
                  )),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottomPad),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                  // ── Gold check circle (matching Trip Accepted style) ──
                  AnimatedBuilder(
                    animation: checkCtrl,
                    builder: (_, __) {
                      return Transform.scale(
                        scale: Curves.elasticOut.transform(
                          checkCtrl.value.clamp(0.0, 1.0),
                        ),
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: gold.withValues(alpha: 0.15),
                            border: Border.all(color: gold, width: 2),
                            boxShadow: [
                              BoxShadow(
                                color: gold.withValues(alpha: 0.3 * checkCtrl.value),
                                blurRadius: 24,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.check_rounded,
                            color: gold,
                            size: 36,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),

                  // ── "Driver Found!" with shimmer ──
                  FadeTransition(
                    opacity: CurvedAnimation(
                      parent: stagger,
                      curve: const Interval(0.15, 0.45),
                    ),
                    child: AnimatedBuilder(
                      animation: shimmer,
                      builder: (_, child) => ShaderMask(
                        shaderCallback: (bounds) => LinearGradient(
                          colors: const [gold, Colors.white, gold],
                          stops: [
                            (shimmer.value - 0.3).clamp(0.0, 1.0),
                            shimmer.value,
                            (shimmer.value + 0.3).clamp(0.0, 1.0),
                          ],
                        ).createShader(bounds),
                        blendMode: BlendMode.srcIn,
                        child: child,
                      ),
                      child: Text(
                        S.of(context).driverFound,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),

                  // ── Subtitle ──
                  FadeTransition(
                    opacity: CurvedAnimation(
                      parent: stagger,
                      curve: const Interval(0.2, 0.5),
                    ),
                    child: Text(
                      '$firstName ${S.of(context).isOnTheWay}',
                      style: const TextStyle(
                        fontSize: 16,
                        color: Colors.white54,
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // ── Driver info card (matching Trip Accepted style) ──
                  FadeTransition(
                    opacity: CurvedAnimation(
                      parent: stagger,
                      curve: const Interval(0.3, 0.6),
                    ),
                    child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: gold.withValues(alpha: 0.2),
                            width: 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: gold.withValues(alpha: 0.08),
                              blurRadius: 20,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            // Driver avatar
                            VerifiedAvatar(
                              uid: driver.id,
                              fallbackName: firstName,
                              photoUrl: driver.photoUrl,
                              radius: 28,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    driver.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      const Icon(Icons.star_rounded,
                                          color: gold, size: 14),
                                      const SizedBox(width: 4),
                                      Text(
                                        driver.rating.toStringAsFixed(1),
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 13,
                                        ),
                                      ),
                                      if (driver.totalTrips > 0) ...[
                                        const SizedBox(width: 12),
                                        Text(
                                          '${driver.totalTrips} trips',
                                          style: const TextStyle(
                                            color: Colors.white38,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  // Vehicle info
                                  Text(
                                    '${driver.vehicleColor} ${driver.vehicleMake} ${driver.vehicleModel}',
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.55),
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  // License plate pill (golden border)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: gold.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: gold.withValues(alpha: 0.3),
                                      ),
                                    ),
                                    child: Text(
                                      driver.vehiclePlate,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 1.8,
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

                  const SizedBox(height: 12),

                  // ── Pickup address pill ──
                  FadeTransition(
                    opacity: CurvedAnimation(
                      parent: stagger,
                      curve: const Interval(0.4, 0.65),
                    ),
                    child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: gold.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: gold.withValues(alpha: 0.3),
                          ),
                        ),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 350),
                          child: Text(
                            messages[_dfMsgIndex],
                            key: ValueKey(_dfMsgIndex),
                            style: const TextStyle(
                              color: gold,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ── Gold progress bar (fills over 3.8 seconds) ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 48),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0.0, end: 1.0),
                      duration: const Duration(milliseconds: 3800),
                      curve: Curves.easeInOut,
                      builder: (_, value, __) => ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: value,
                          backgroundColor: Colors.white12,
                          valueColor: const AlwaysStoppedAnimation(gold),
                          minHeight: 3,
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
            ],
          ),
        ),
      ),
    );
  }

  // ── Helpers ──

  Widget _circleButton({
    required IconData icon,
    required VoidCallback onTap,
    required AppColors c,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, size: 24, color: Colors.white),
      ),
    );
  }
}
