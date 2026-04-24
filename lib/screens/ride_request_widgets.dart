part of 'ride_request_screen.dart';

// ════════════════════════════════════════════════════════════
//  WIDGETS — panels, cards, overlays
// ════════════════════════════════════════════════════════════

extension _RideRequestWidgets on _RideRequestScreenState {

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

  // ── Route preview sheet — 1:1 port of the web widget's step-3 sheet ──
  //
  // Web HTML structure:
  //   .vipRide__sheet[data-vipride-step="3"]     ← outer container
  //     .vipRide__prices                         ← content wrapper
  //       .vipRide__pricesHeader
  //         .vipRide__pricesTitle                ← "Choose a Ride"
  //       .vipRide__rideList                     ← 3-column grid
  //         .vipRide__rideCard × 3
  //       .vipRide__rideDetail                   ← shown after selection
  //       .vipRide__actionBtns                   ← Payment + Request buttons
  //
  // CSS ref (liquid lines 681, 742-806):
  //   outer:   background:#1a1a1f; border-radius:20px;
  //            border:1px solid rgba(255,255,255,.06);
  //            box-shadow:0 2px 10px rgba(232,197,71,.06),
  //                       0 8px 40px rgba(0,0,0,.5);
  //            padding:14px 14px calc(14px + env(safe-area-inset-bottom));
  //            max-height:60svh; overflow-y:auto;
  //   title:   Poppins 800 clamp(16px,4.5vw,20px) letter-spacing:-.03em center
  //   list:    display:grid grid-template-columns:repeat(3,1fr) gap:8px
  //   detail:  margin-top:14px padding:14px border-radius:14px
  //            bg:linear-gradient(135deg, rgba(232,197,71,.06),
  //                                       rgba(255,255,255,.02));
  //            border:1px solid rgba(232,197,71,.18)
  //   actions: margin-top:12px display:flex flex-direction:column gap:8px
  Widget _buildRoutePreviewSheet(AppColors c, double bottomPad) {
    final s = _ctrl.state;

    // Fast-ride tier override (single "Comfort" option, ~$160/hr).
    List<RideOption> displayOptions = s.rideOptions;
    if (widget.fastRide && s.rideOptions.isNotEmpty) {
      final baseFusion = s.rideOptions.last;
      final expressPrice =
          (baseFusion.priceEstimate * 3.2).roundToDouble();
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

    // 10% promo discount.
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
    // Match web's max-height:60svh.
    final sheetMaxH = screenH * 0.60;

    return Positioned(
      left: 8,
      right: 8,
      bottom: 10,
      // Sheet is visible the instant we enter previewRoute/selectingRide.
      // No fade-in coupling with the map cinematic — matches the web.
      child: AnimatedOpacity(
        opacity: 1.0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        child: Container(
          constraints: BoxConstraints(maxHeight: sheetMaxH),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1F),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFE8C547).withValues(alpha: 0.06),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.50),
                blurRadius: 40,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(14, 14, 14, 14 + bottomPad),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Payment-declined banner (kept as a top slot — it's
                  // critical domain info and the web shows a similar
                  // dismissible row above the header).
                  if (_showPaymentDeclinedBanner) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF3D0000),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: const Color(0xFFB71C1C), width: 1),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline_rounded,
                              color: Color(0xFFEF9A9A), size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              S.of(context).paymentDeclinedMsg,
                              style: const TextStyle(
                                  color: Color(0xFFEF9A9A), fontSize: 13),
                            ),
                          ),
                          GestureDetector(
                            onTap: () => _setState(
                                () => _showPaymentDeclinedBanner = false),
                            child: const Icon(Icons.close_rounded,
                                color: Color(0xFFEF9A9A), size: 18),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],

                  // .vipRide__pricesHeader — centered title row with
                  // optional Airport / 10% OFF pills to the side.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        widget.fastRide
                            ? S.of(context).fastRideLabel
                            : S.of(context).chooseARide,
                        style: const TextStyle(
                          fontFamily: 'Poppins',
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: -0.6, // -.03em × 20px
                        ),
                      ),
                      if (_ctrl.state.isAirportTrip) ...[
                        const SizedBox(width: 8),
                        _headerPill(
                          icon: Icons.flight_rounded,
                          text: S.of(context).airportLabel,
                          color: const Color(0xFF4285F4),
                        ),
                      ],
                      if (widget.applyPromo) ...[
                        const SizedBox(width: 8),
                        _headerPill(
                          text: '10% OFF',
                          color: const Color(0xFFE8C547),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 12),

                  // .vipRide__rideList — 3-column grid, always visible.
                  if (_ctrl.state.routeFetchFailed && displayOptions.isEmpty)
                    _buildRouteFailedRetry()
                  else if (displayOptions.isEmpty)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (int i = 0; i < 3; i++) ...[
                          Expanded(child: _buildShimmerCard()),
                          if (i < 2) const SizedBox(width: 8),
                        ],
                      ],
                    )
                  else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (int i = 0; i < displayOptions.length; i++) ...[
                          Expanded(
                            key: ValueKey(
                                'ride_opt_${displayOptions[i].id}'),
                            child: _PressableScale(
                              onTap: () {
                                HapticFeedback.selectionClick();
                                _ctrl.selectRideOption(displayOptions[i]);
                                if (_mapCtrl != null && !_cinematicRunning) {
                                  final st = _ctrl.state;
                                  if (st.pickup != null &&
                                      st.dropoff != null) {
                                    final pts = st.route?.points ??
                                        [
                                          LatLng(st.pickup!.lat,
                                              st.pickup!.lng),
                                          LatLng(st.dropoff!.lat,
                                              st.dropoff!.lng),
                                        ];
                                    Future.delayed(
                                        const Duration(milliseconds: 350),
                                        () {
                                      if (mounted && !_cinematicRunning) {
                                        _fitRoute(pts, preserveCamera: true);
                                      }
                                    });
                                  }
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
                            const SizedBox(width: 8),
                        ],
                      ],
                    ),

                  // .vipRide__rideDetail — appears only after a tier is
                  // picked. Web uses margin-top:14px.
                  if (option != null) ...[
                    const SizedBox(height: 14),
                    _buildRideDetailPanel(c, option),
                  ],

                  // .vipRide__actionBtns — payment selector + Request Ride.
                  // Web: margin-top:12px flex-direction:column gap:8px,
                  // with a 250ms / 400ms staggered vipFB fade-in.
                  if (option != null) ...[
                    const SizedBox(height: 12),
                    _StaggeredFade(
                      key: ValueKey('pay_${option.id}'),
                      delayMs: 250,
                      child: _PaymentMethodButton(
                        onTap: () => _showPaymentMethodPicker(c, option),
                        selectedMethod: _selectedPaymentMethod,
                        logoBuilder: _paymentLogoWidget,
                        labelBuilder: _paymentLabel,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _StaggeredFade(
                      key: ValueKey('req_${option.id}'),
                      delayMs: 400,
                      child: _WebRequestButton(
                        enabled: !_isProcessingPayment &&
                            _hasAnyPaymentMethod,
                        isLoading: _isProcessingPayment,
                        label: widget.scheduledAt != null
                            ? S.of(context).bookScheduledRide
                            : S.of(context).requestRide,
                        onTap: () {
                          HapticFeedback.mediumImpact();
                          _startRideDirectly(c, option);
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Small pill used in the sheet header (airport / promo chips).
  Widget _headerPill({
    IconData? icon,
    required String text,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
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

  // .vipRide__rideCard port — vertical grid card, 1:1 with the web.
  //   padding: 10px 8px
  //   border-radius: 14px
  //   background: rgba(255,255,255,.02) / rgba(232,197,71,.08) active
  //   border: 1px rgba(255,255,255,.08) / rgba(232,197,71,.7) active
  //   outline: 2px rgba(232,197,71,.55) active (inset, -1px offset)
  //   rideGlow 2.8s active pulse
  //   :active transform scale(.96)
  Widget _buildRideOptionCard(AppColors c, RideOption opt, bool selected) {
    final isSuv = opt.id == 'suburban';
    final isFusion = opt.id == 'fusion';

    final bool isVIP = isSuv;
    final bool isPremium = !isSuv && !isFusion;
    final String tierLabel = isVIP ? 'VIP' : (isPremium ? 'PREMIUM' : 'COMFORT');
    final String displayName = isVIP ? 'BLACK' : (isPremium ? 'PREMIUM' : 'STANDARD');

    return AnimatedBuilder(
      animation: selected ? _activeCardGlowCtrl : kAlwaysDismissedAnimation,
      builder: (_, __) {
        // rideGlow keyframe pair — 0%/100% vs 50% midpoint on a 2.8s
        // ease-in-out loop. Triangle wave 0 → 1 → 0.
        final t = selected ? _activeCardGlowCtrl.value : 0.0;
        final glowInner = 0.15 + 0.15 * t; // matches rgba shadow stop
        final glowOuter = 0.18 + 0.15 * t;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0x14E8C547) // rgba(232,197,71,.08)
                : Colors.white.withValues(alpha: 0.02),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? const Color(0xB3E8C547) // rgba(232,197,71,.7)
                  : Colors.white.withValues(alpha: 0.08),
              width: selected ? 1 : 1,
            ),
            boxShadow: selected
                ? [
                    // rideGlow 0%: 0 0 0 1px rgba(232,197,71,.3),
                    //              0 6px 18px rgba(232,197,71,.15)
                    // rideGlow 50%: 0 0 0 1px rgba(232,197,71,.5),
                    //               0 8px 24px rgba(232,197,71,.3)
                    BoxShadow(
                      color: const Color(0xFFE8C547)
                          .withValues(alpha: 0.3 + 0.2 * t),
                      blurRadius: 0,
                      spreadRadius: 1,
                    ),
                    BoxShadow(
                      color: const Color(0xFFE8C547).withValues(alpha: glowInner),
                      blurRadius: 18 + 6 * t,
                      offset: const Offset(0, 6),
                    ),
                    BoxShadow(
                      color: const Color(0xFFE8C547).withValues(alpha: glowOuter * 0.5),
                      blurRadius: 24 + 8 * t,
                      spreadRadius: -2,
                    ),
                  ]
                : const [
                    BoxShadow(
                      color: Color(0x2E000000),
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    ),
                  ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Inner outline 2px rgba(232,197,71,.55) offset -1px —
              // web uses `outline: 2px solid ... outline-offset: -1px`
              // which draws inside the card. Emulated here with a
              // positioned ring.
              if (selected)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      margin: const EdgeInsets.all(1),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: const Color(0x8CE8C547), // rgba(232,197,71,.55)
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),
              Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // .vipRide__rideImgTag — max-height clamp(40,11vw,52),
                  // two-layer drop-shadow for depth.
                  SizedBox(
                    height: 52,
                    child: CarImage3D(
                      assetPath: _carAssetForOption(opt.name),
                      cacheWidth: 240,
                      dimmed: !selected,
                      dimDuration: const Duration(milliseconds: 180),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // .vipRide__rideName — 17px max, weight 700,
                  // letter-spacing .02em, line-height 1.3.
                  Text(
                    displayName,
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      color: Colors.white,
                      fontSize: 15, // clamp floor; grid cell is narrow
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.34, // .02em × 17px
                      height: 1.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  VehicleTierBadge(
                    tier: tierLabel == 'VIP'
                        ? VehicleTier.vip
                        : tierLabel == 'PREMIUM'
                            ? VehicleTier.premium
                            : VehicleTier.comfort,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // Floating gold-border labels ("RECOGIDA" / "DESTINO") that sit
  // above each pin tip, matching the Shopify widget's .vipRide__mapLabel.
  // Positions are driven by _pickupScreenOffset / _dropoffScreenOffset
  // which are recomputed on every camera change via _syncLabelOffsets().
  List<Widget> _buildFloatingLabels() {
    final s = _ctrl.state;
    final widgets = <Widget>[];
    final loc = S.of(context);
    final pickupText = loc.pickupUpperLabel; // "RECOGIDA" / "PICKUP"
    final dropoffText = loc.dropoffUpperLabel; // "DESTINO" / "DROPOFF"

    final pickupPos = _pickupScreenOffset;
    if (pickupPos != null && s.pickupLabel.isNotEmpty) {
      widgets.add(
        Positioned(
          // Offset up-and-right of the pin tip so the label floats
          // beside the pin rather than covering it.
          left: pickupPos.dx + 14,
          top: pickupPos.dy - 82,
          child: AnimatedMapLabel(
            kind: MapLabelKind.pickup,
            address: s.pickupLabel,
            pickupText: pickupText,
            dropoffText: dropoffText,
            visible: _pickupLabelRevealed,
            alignEnd: false,
          ),
        ),
      );
    }

    final dropoffPos = _dropoffScreenOffset;
    if (dropoffPos != null && s.dropoffLabel.isNotEmpty) {
      widgets.add(
        Positioned(
          // Offset up-and-left for dropoff (mirrored side of the pin).
          left: dropoffPos.dx - 220,
          top: dropoffPos.dy - 82,
          child: AnimatedMapLabel(
            kind: MapLabelKind.dropoff,
            address: s.dropoffLabel,
            pickupText: pickupText,
            dropoffText: dropoffText,
            visible: _dropoffLabelRevealed,
            alignEnd: true,
          ),
        ),
      );
    }
    return widgets;
  }

  // Detail panel shown below the 3-card grid once the user has picked a
  // tier. Matches .vipRide__rideDetail from the web (description + eta
  // row + big price).
  Widget _buildRideDetailPanel(AppColors c, RideOption opt) {

    // 650ms cubic-bezier(.4,0,.2,1) slide-down 6px — matches the web's
    // .vipRide__rideDetail animation keyframe vipRideDetailIn.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 650),
      switchInCurve: const Cubic(0.4, 0, 0.2, 1),
      transitionBuilder: (child, anim) {
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(
              // -6px in CSS translates to approximately -0.04 of the
              // container height on average — close enough visually.
              begin: const Offset(0, -0.04),
              end: Offset.zero,
            ).animate(anim),
            child: child,
          ),
        );
      },
      child: Container(
        key: ValueKey('detail_${opt.id}'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              _cardGold.withValues(alpha: 0.06),
              Colors.white.withValues(alpha: 0.02),
            ],
          ),
          border: Border.all(
            color: _cardGold.withValues(alpha: 0.18),
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // .vipRide__rideDetail__desc: 13px, color rgba(255,255,255,.75),
            // line-height 1.4, default weight 400.
            Text(
              opt.description,
              style: TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 13,
                fontWeight: FontWeight.w400,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            // Web (.vipRide__rideDetail__meta) shows exactly two chips:
            // ETA minutes and capacity. No arrival-time chip — port must
            // match this to avoid looking cluttered.
            Row(
              children: [
                _chipWidget(Icons.schedule_rounded, '${opt.etaMinutes} min'),
                const SizedBox(width: 6),
                _chipWidget(Icons.person_rounded, '${opt.capacity}'),
                const Spacer(),
                if (_ctrl.state.route == null)
                  _buildPriceShimmer(width: 68, height: 22)
                else
                  // .vipRide__rideDetail__price: clamp(18,5vw,22)
                  // weight 800 color #fff.
                  Text(
                    '\$${opt.priceEstimate.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── OLD card kept for reference during migration — now unused ──
  // ignore: unused_element
  Widget _buildRideOptionCardLegacy(AppColors c, RideOption opt, bool selected) {
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        // Gold crystal / glass effect when selected
        color: selected
            ? const Color(0xFF1A1708)
            : const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected
              ? _cardGold.withValues(alpha: 0.65)
              : Colors.white.withValues(alpha: 0.06),
          width: selected ? 1.5 : 1.0,
        ),
        gradient: selected
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF2A2210),
                  Color(0xFF1A1708),
                  Color(0xFF221E0C),
                ],
              )
            : null,
        boxShadow: selected
            ? [
                BoxShadow(
                  color: _cardGold.withValues(alpha: 0.10),
                  blurRadius: 48,
                  spreadRadius: -4,
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
      child: Stack(
        children: [
          // Crystal overlay shine for selected card
          if (selected)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          _cardGold.withValues(alpha: 0.08),
                          Colors.transparent,
                          _cardGold.withValues(alpha: 0.04),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Row(
        children: [
          // Left — Badge above car
          SizedBox(
            width: 100,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Tier badge — animated gradient pill (matches home_screen)
                AnimatedBuilder(
                  animation: badgeAnim,
                  builder: (_, __) {
                    final t = badgeAnim.value;
                    // Pulsing outer glow intensity
                    final glowAlpha = (0.35 + 0.25 * math.sin(t * 2 * math.pi)).clamp(0.0, 1.0);
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
                                color: accent.withValues(alpha: glowAlpha),
                                blurRadius: 16 + 6 * math.sin(t * 2 * math.pi),
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
                        // VIP: dual-layer gold shimmer
                        if (isVIP) ...[
                          // Layer 1 — wide soft gold glow
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: IgnorePointer(
                                child: Transform.translate(
                                  offset: Offset(200 * (t * 2.0 - 0.5), 0),
                                  child: Container(
                                    width: 56,
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(colors: [
                                        Colors.transparent,
                                        const Color(0xFFFFE88A).withValues(alpha: 0.35),
                                        Colors.transparent,
                                      ]),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // Layer 2 — thin bright white streak
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: IgnorePointer(
                                child: Transform.translate(
                                  offset: Offset(180 * (t * 2.6 - 0.8), 0),
                                  child: Transform.rotate(
                                    angle: 0.35,
                                    child: Container(
                                      width: 14,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(colors: [
                                          Colors.transparent,
                                          Colors.white.withValues(alpha: 0.7),
                                          Colors.transparent,
                                        ]),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                        // Premium: sleek metallic diagonal sweep
                        if (isPremium)
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: IgnorePointer(
                                child: Transform.translate(
                                  offset: Offset(180 * (t * 2.4 - 0.7), 0),
                                  child: Transform.rotate(
                                    angle: 0.3,
                                    child: Container(
                                      width: 22,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(colors: [
                                          Colors.transparent,
                                          Colors.white.withValues(alpha: 0.55),
                                          const Color(0xFFE0E0E0).withValues(alpha: 0.25),
                                          Colors.transparent,
                                        ]),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        // Comfort: sweeping green light
                        if (isComfort)
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: IgnorePointer(
                                child: Transform.translate(
                                  offset: Offset(180 * (t * 2.4 - 0.7), 0),
                                  child: Transform.rotate(
                                    angle: 0.3,
                                    child: Container(
                                      width: 26,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(colors: [
                                          Colors.transparent,
                                          const Color(0xFF81C784).withValues(alpha: 0.5),
                                          Colors.transparent,
                                        ]),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 2),
                // Car image
                SizedBox(
                  height: 56,
                  child: CarImage3D(
                    assetPath: _carAssetForOption(opt.name),
                    cacheWidth: 216,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),

          // Info column
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Description
                Text(
                  opt.description,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFFE8C547),
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 3),
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
          const SizedBox(width: 48),
        ],   // Row children
      ),     // Row
          // Price + est. fare — top-right corner
          Positioned(
            top: 0,
            right: 0,
            child: Column(
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
                      color: selected ? const Color(0xFFD0D4DC) : const Color(0xFFB0B4BC),
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
              ],
            ),
          ),
          // Checkmark — bottom-right when selected
          if (selected)
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
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
            ),
        ],   // Stack children  
      ),     // Stack
    ),       // AnimatedContainer
    );       // AnimatedScale
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
            Color(0xFF1A1A1A),
            Color(0xFF2A2A2A),
            Color(0xFF1A1A1A),
          ],
          stops: const [0.0, 0.5, 1.0],
        );
        // Vertical placeholder that mirrors the real 3-column grid
        // card: car image on top, tier name in the middle, badge at
        // the bottom. Keeps the layout stable while options load.
        return Container(
          padding: const EdgeInsets.fromLTRB(6, 10, 6, 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.02),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Car image placeholder
              Container(
                height: 48,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  gradient: gradient,
                ),
              ),
              const SizedBox(height: 10),
              // Name placeholder
              Container(
                width: 60,
                height: 12,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  gradient: gradient,
                ),
              ),
              const SizedBox(height: 8),
              // Badge placeholder
              Container(
                width: 70,
                height: 20,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  gradient: gradient,
                ),
              ),
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
              _setState(() {});
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
    final msgs = _getSearchStatusMessages(context);
    final statusMsg = msgs[_searchStatusIdx % msgs.length];
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
      // Pure fade — no slide. The card fades in smoothly over 420ms
      // so it feels connected to the SearchingDriverScreen cross-fade
      // that's happening at the same time.
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeInOutCubic,
        opacity: _searchingShowMap ? 1.0 : 0.0,
        child: IgnorePointer(
          ignoring: !_searchingShowMap,
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

                        // ── Web .vipRide__testSheet__icon port ──
                        //
                        //   48×48 gold circle icon (bg rgba(232,197,71,.1),
                        //   border 1.5px rgba(232,197,71,.35), box-shadow
                        //   0 0 16px rgba(232,197,71,.15)) with two pseudo-
                        //   element rings ::before (58×58) and ::after
                        //   (72×72, delay 0.9s) running vipTestPulse 2.8s
                        //   cubic-bezier(.4,0,.2,1) infinite, scale .6 → 1.25,
                        //   opacity 0 → .55 @15% → 0.
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 72,
                              height: 72,
                              child: AnimatedBuilder(
                                animation: _radarCtrl,
                                builder: (context, _) {
                                  Widget ring(double baseSize, double delay) {
                                    // _radarCtrl runs 2400ms; normalize to 2.8s
                                    // and offset by delay (0 or 0.9s).
                                    final t = ((_radarCtrl.value * 2400 - delay * 1000) /
                                            2800)
                                        .clamp(0.0, 1.0);
                                    final scale = 0.6 + (1.25 - 0.6) * t;
                                    final opacity = t < 0.15
                                        ? (t / 0.15) * 0.55
                                        : 0.55 * (1 - (t - 0.15) / 0.85);
                                    return Transform.scale(
                                      scale: scale,
                                      child: Container(
                                        width: baseSize,
                                        height: baseSize,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: const Color(0xFFE8C547)
                                                .withValues(alpha: opacity.clamp(0.0, 1.0)),
                                            width: 1.5,
                                          ),
                                        ),
                                      ),
                                    );
                                  }

                                  return Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      // ::after — 72×72, 0.9s delay
                                      ring(72, 0.9),
                                      // ::before — 58×58, no delay
                                      ring(58, 0),
                                      // 48×48 icon circle
                                      Container(
                                        width: 48,
                                        height: 48,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFE8C547)
                                              .withValues(alpha: 0.10),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: const Color(0xFFE8C547)
                                                .withValues(alpha: 0.35),
                                            width: 1.5,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: const Color(0xFFE8C547)
                                                  .withValues(alpha: 0.15),
                                              blurRadius: 16,
                                            ),
                                          ],
                                        ),
                                        alignment: Alignment.center,
                                        child: const Icon(
                                          Icons.local_taxi_rounded,
                                          color: Color(0xFFE8C547),
                                          size: 22,
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 14),

                            // ── Status + route ──
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Animated status message
                                  SizedBox(
                                    height: 22,
                                    child: AnimatedSwitcher(
                                      duration: const Duration(milliseconds: 400),
                                      switchInCurve: Curves.easeOutCubic,
                                      switchOutCurve: Curves.easeInCubic,
                                      transitionBuilder: (child, anim) {
                                        final slideIn = Tween<Offset>(
                                          begin: const Offset(0, 0.5),
                                          end: Offset.zero,
                                        ).animate(anim);
                                        return SlideTransition(
                                          position: slideIn,
                                          child: FadeTransition(
                                            opacity: anim,
                                            child: child,
                                          ),
                                        );
                                      },
                                      layoutBuilder: (currentChild, previousChildren) {
                                        return Stack(
                                          alignment: AlignmentDirectional.centerStart,
                                          children: [
                                            ...previousChildren,
                                            if (currentChild != null) currentChild,
                                          ],
                                        );
                                      },
                                      child: Text(
                                        statusMsg,
                                        key: ValueKey(statusMsg),
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                          letterSpacing: -0.2,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
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

                        // ── .vipRide__testCancelBtn port ──
                        //   background:none; border:none;
                        //   font-size: 14-16px; color: rgba(255,255,255,.45);
                        //   padding: 12px 28px; transition: color 200ms;
                        //   :active color: rgba(255,255,255,.8);
                        InkWell(
                          onTap: _confirmCancelSearching,
                          borderRadius: BorderRadius.circular(8),
                          splashColor: Colors.transparent,
                          highlightColor: Colors.white.withValues(alpha: 0.04),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 28, vertical: 12),
                            child: Text(
                              S.of(context).cancel,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                color: Colors.white.withValues(alpha: 0.45),
                                letterSpacing: 0.1,
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
      case 'test_mode':
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: const Color(0xFFFF3B30).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Center(
            child: Icon(
              Icons.bug_report_rounded,
              color: Color(0xFFFF3B30),
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
                        try { await ctrl.style.setStyleLayerProperty(pointMgr.id, 'icon-pitch-alignment', 'viewport'); } catch (_) {}
                        try { await ctrl.style.setStyleLayerProperty(pointMgr.id, 'icon-allow-overlap', true); } catch (_) {}
                        try { await ctrl.style.setStyleLayerProperty(pointMgr.id, 'icon-ignore-placement', true); } catch (_) {}
                        try { await ctrl.style.setStyleLayerProperty(pointMgr.id, 'icon-anchor', 'bottom'); } catch (_) {}
                        final pickupBytes =
                            await renderCircularPinBytes(icon: CircularPinIcon.person, isPickup: true, radius: 44);
                        await pointMgr.create(mapbox.PointAnnotationOptions(
                          geometry: mapbox.Point(
                            coordinates:
                                mapbox.Position(pickup.lng, pickup.lat),
                          ),
                          image: pickupBytes,
                          iconSize: 0.65,
                          iconAnchor: mapbox.IconAnchor.BOTTOM,
                          iconOffset: [0, 0],
                        ));
                        if (dropoff != null) {
                          final dropoffBytes =
                              await renderCircularPinBytes(icon: CircularPinIcon.home, isPickup: false, radius: 44);
                          await pointMgr.create(mapbox.PointAnnotationOptions(
                            geometry: mapbox.Point(
                              coordinates:
                                  mapbox.Position(dropoff.lng, dropoff.lat),
                            ),
                            image: dropoffBytes,
                            iconSize: 0.65,
                            iconAnchor: mapbox.IconAnchor.BOTTOM,
                            iconOffset: [0, 0],
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
                              role: 'driver',
                              isVerified: true,
                            ),
                            const SizedBox(width: 12),
                            // Name + rating
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
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
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
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  // Vehicle info
                                  Text(
                                    '${driver.vehicleColor} ${driver.vehicleMake} ${driver.vehicleModel}',
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.55),
                                      fontSize: 13,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            // License plate pill (right side)
                            if (driver.vehiclePlate.isNotEmpty)
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

// ═══════════════════════════════════════════════════════════════════
//  Web Request Button — direct port of .vipRide__requestBtn
//  (005_09-28-46_260627b.liquid:804).
//    width: 100%; padding: 16px; border-radius: 12px;
//    background: #E8C547 (solid, no gradient);
//    font-size: 16px; font-weight: 800; color: #0a0e1a;
//    box-shadow:
//      0 2px 8px rgba(232,197,71,.25),
//      0 6px 20px rgba(0,0,0,.2);
//    :active:not(:disabled) → transform: scale(.97);
//    :disabled → opacity: .35;
// ═══════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════
// _PaymentMethodButton — 1:1 port of .vipRide__paymentBtn
// ─────────────────────────────────────────────────────────────────────
// CSS ref (liquid line 801-803):
//   width:100% display:flex align-items:center gap:10px
//   padding:12px 14px border-radius:12px
//   background:rgba(255,255,255,.06)
//   border:1px solid rgba(255,255,255,.1)
//   :active { background:rgba(255,255,255,.1) }
// ═══════════════════════════════════════════════════════════════════
class _PaymentMethodButton extends StatefulWidget {
  final VoidCallback onTap;
  final String selectedMethod;
  final Widget Function(String method, double size) logoBuilder;
  final String Function(String method) labelBuilder;

  const _PaymentMethodButton({
    required this.onTap,
    required this.selectedMethod,
    required this.logoBuilder,
    required this.labelBuilder,
  });

  @override
  State<_PaymentMethodButton> createState() => _PaymentMethodButtonState();
}

class _PaymentMethodButtonState extends State<_PaymentMethodButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: _pressed ? 0.10 : 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.10),
          ),
        ),
        child: Row(
          children: [
            // Icon container — web uses an inline icon at 26×26, we use
            // the widget's logoBuilder so the Apple / Google / Card /
            // Test Mode graphics stay identical to the payment picker.
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: SizedBox(
                key: ValueKey('payLogo_${widget.selectedMethod}'),
                child: widget.logoBuilder(widget.selectedMethod, 26),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: Align(
                  key: ValueKey('payLabel_${widget.selectedMethod}'),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    widget.labelBuilder(widget.selectedMethod),
                    style: const TextStyle(
                      fontFamily: 'Poppins',
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            // Trailing chevron — web uses a right-arrow SVG at 7×12.
            Icon(
              Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.4),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _WebRequestButton extends StatefulWidget {
  final bool enabled;
  final bool isLoading;
  final String label;
  final VoidCallback onTap;

  const _WebRequestButton({
    required this.enabled,
    required this.isLoading,
    required this.label,
    required this.onTap,
  });

  @override
  State<_WebRequestButton> createState() => _WebRequestButtonState();
}

class _WebRequestButtonState extends State<_WebRequestButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !widget.isLoading;
    return GestureDetector(
      onTap: enabled ? widget.onTap : null,
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        // .vipRide__requestBtn:active:not(:disabled) { transform: scale(.97); }
        scale: (_pressed && enabled) ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedOpacity(
          // :disabled { opacity: .35; }
          opacity: enabled ? 1.0 : 0.35,
          duration: const Duration(milliseconds: 160),
          child: Container(
            width: double.infinity,
            // padding: 16px;
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
            decoration: BoxDecoration(
              // background: #E8C547 (solid, no gradient)
              color: const Color(0xFFE8C547),
              // border-radius: 12px
              borderRadius: BorderRadius.circular(12),
              // box-shadow:
              //   0 2px 8px rgba(232,197,71,.25),
              //   0 6px 20px rgba(0,0,0,.2);
              boxShadow: const [
                BoxShadow(
                  color: Color(0x40E8C547),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 20,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: widget.isLoading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Color(0xFF0A0E1A),
                    ),
                  )
                : Text(
                    widget.label,
                    style: const TextStyle(
                      // font-size: 16px; font-weight: 800; color: #0a0e1a;
                      fontFamily: 'Poppins',
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0A0E1A),
                      letterSpacing: -0.2,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  _PressableScale — scale(.96) on tap-down matching the web's
//  .vipRide__rideCard:active { transform: scale(.96) }.
// ═══════════════════════════════════════════════════════════════════
class _PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const _PressableScale({required this.child, required this.onTap});

  @override
  State<_PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<_PressableScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: const Cubic(0, 0, 0.2, 1),
        child: widget.child,
      ),
    );
  }
}

// Fade-in after a delay — matches the web's staggered reveal
// (payment button @ 250ms, request button @ 400ms).
class _StaggeredFade extends StatefulWidget {
  final Widget child;
  final int delayMs;
  const _StaggeredFade({super.key, required this.child, required this.delayMs});
  @override
  State<_StaggeredFade> createState() => _StaggeredFadeState();
}

class _StaggeredFadeState extends State<_StaggeredFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    Future.delayed(Duration(milliseconds: widget.delayMs), () {
      if (mounted) _ctl.forward();
    });
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: _ctl, curve: Curves.easeOutCubic),
      child: widget.child,
    );
  }
}
