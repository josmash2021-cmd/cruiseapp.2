part of 'ride_request_screen.dart';

/// Minutes, and hours once there are sixty of them.
///
/// "122 min" makes the rider divide by hand to find out their trip is two
/// hours. Sixty is where the unit changes, everywhere a duration is printed.
///
/// Exact, not rounded: this is the estimate the fare was computed from, and a
/// number the rider can check against the receipt afterwards.
///
/// Top-level rather than a method — a part file can only reach top-level
/// declarations from inside a const expression, and this file is a part.
///
/// "min" and "h" are the same word in both languages the app speaks.
String durationLabel(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}

final _whitespaceRe = RegExp(r'\s+');

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
                  onTap: () => _nav?.pop(),
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

    // Still no fabricated prices — but the sheet is never empty either.
    //
    // A booking sheet with nothing in it reads as broken however it got that
    // way: no route, no pickup, a fare call still in flight. The four tiers
    // are known without any of that, so they are drawn regardless, and the
    // one thing that cannot be known — the money — is left as a dash.
    //
    // The old rule stands and is what makes this safe: a price of zero is
    // never printed as a price, and Request Ride is disabled until real
    // fares land, so nobody can book at a rate the app made up.
    final bool faresReady = displayOptions.isNotEmpty;
    if (!faresReady) displayOptions = _placeholderTiers();

    // Fixed top→bottom tier order (user spec 2026-08-22): Black, Premium,
    // Compact, Standard. The controller already builds them in this order;
    // the sort pins it IN THE SHEET (prices and every other consumer of
    // rideOptions keep their own order untouched), so nothing upstream can
    // reshuffle the rider's list. Unknown ids sink to the bottom, stable.
    const tierOrder = ['suburban', 'suv_xl', 'camry', 'fusion'];
    displayOptions = [...displayOptions]..sort((a, b) {
      final ia = tierOrder.indexOf(a.id);
      final ib = tierOrder.indexOf(b.id);
      return (ia < 0 ? tierOrder.length : ia)
          .compareTo(ib < 0 ? tierOrder.length : ib);
    });
    _displayTierCount = displayOptions.length;

    final option = widget.fastRide
        ? (displayOptions.isNotEmpty ? displayOptions.first : s.selectedOption)
        : s.selectedOption;

    // Positioned(top:0,bottom:10,left:8,right:8) gives the child a FULLY
    // bounded box (finite width AND finite height). Align(bottomCenter)
    // then collapses unused vertical space and hugs the Column(min) to
    // the bottom. No Material/ConstrainedBox/AnimatedOpacity needed —
    // those layers were introducing the intrinsic-height ambiguity that
    // kept collapsing the sheet on iOS.
    // Floating sheet: 14px side margins, 24px bottom gap from screen
    // edge so it visibly hovers above the map instead of hugging the
    // bottom. Stronger drop shadow + subtle gold-tinted top glow sells
    // the "lifted" feel.
    // Floating while it is only the four cards, flush once a tier is picked.
    //
    // This was one or the other and both were wrong half the time. It hovered
    // with 14 px down each side and 24 px of map beneath, which looks right
    // over a map but costs height at the top of the sheet — and the sheet is
    // what pushes the map up, so on a long trip the route ran under the panel.
    // Made flush, that came back, but a short four-card panel welded to the
    // bottom edge reads as a wall rather than a choice.
    //
    // Which one is right depends on how tall the sheet is, and that is exactly
    // what picking a tier changes. Unpicked it is short and there is map to
    // spare, so it floats. Picked it grows by the detail row, the payment row
    // and the button, and every pixel of that goes to the content instead of
    // to margins.
    final bool floating = option == null;

    return AnimatedPositioned(
      // Moves with the card row rather than after it, so the panel settling
      // against the edge is part of the same gesture as the tiers collapsing.
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeInOutCubicEmphasized,
      // No `top` — bottom-anchored, height from the content.
      //
      // It was pinned top AND bottom while being made flush to the edges,
      // which stops being a bottom sheet: pinned on both sides the box is
      // the full height of the screen, so the panel took the whole display
      // and the map disappeared behind it. Anchoring only the bottom lets
      // the sheet be as tall as what is in it and no taller.
      left: floating ? 14 : 0,
      right: floating ? 14 : 0,
      bottom: floating ? 24 : 0,
      child: Align(
        alignment: Alignment.bottomCenter,
        // Measure the panel's real height — the camera fit and the address
        // bar anchor to this, not to a fraction-of-screen estimate.
        child: _SheetSizeReporter(
          onChanged: _onSheetHeightChanged,
          // One reporter around BOTH the sheet and the floating action
          // panel under it, so the route fit clears the pair. SafeArea
          // moves out here too: in flush mode it is the action panel —
          // not the sheet — that meets the system nav bar.
          child: SafeArea(
            top: false,
            // viewPadding, not padding: padding can arrive already consumed
            // by an ancestor, and on Android that left the Request Ride
            // button under the system nav/gesture bar (user report
            // 2026-08-04). viewPadding always carries the real bar height;
            // minimum guarantees it even when SafeArea's own padding
            // lookup reads 0. Flush mode only — floating already hovers
            // 24px above the edge.
            minimum: EdgeInsets.only(
              bottom: floating
                  ? 0
                  : MediaQuery.viewPaddingOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeInOutCubicEmphasized,
            // Rounded all round while it floats, top-only once it meets the
            // screen edges — neuBox cannot express either, so its two shadows
            // are replicated on neuSurface here (same treatment as the
            // driver's panel).
            decoration: BoxDecoration(
              // neuBase, not neuSurface — this is the ground the cards sit on.
              //
              // The style file labels them: neuBase is "screen/sheet
              // background", neuSurface is "raised surface (cards)". Painted
              // in neuSurface, the sheet was the same tone as the cards on it,
              // so four raised tiles were sitting on another raised surface
              // with nothing between them. The shadows were drawing the whole
              // time — there was just no change in level for them to describe,
              // and neumorphism is only ever a description of level.
              color: neuBase,
              borderRadius: floating
                  ? BorderRadius.circular(26)
                  : const BorderRadius.vertical(top: Radius.circular(26)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.55),
                  blurRadius: 24,
                  offset: const Offset(0, -8),
                ),
                BoxShadow(
                  color: Colors.white.withValues(alpha: 0.03),
                  blurRadius: 1,
                  offset: const Offset(0, -1),
                ),
              ],
            ),
            // The sheet is as tall as what is in it. No ceiling, no scroll.
            //
            // It used to be capped at 40% of the screen with a scroll view
            // underneath, which fit the four cards and nothing else: pick a
            // tier and the panel grows by the detail row, the payment row
            // and the button, and Request Ride ended up past the bottom
            // edge — the one control this screen exists for, reachable only
            // by scrolling a panel that does not look scrollable.
            //
            // The cap was there because the height used to drift: three
            // layout faults in two builds came from adding a row and not
            // recomputing what it displaced. That risk is real and it comes
            // back with this. It is the right trade anyway — a sheet that
            // is sometimes taller than intended is a smaller problem than
            // a button nobody can reach — but anything added below must be
            // checked against a short handset, because there is no longer a
            // scroll view to absorb it.
            child: Padding(
                // Bottom is tighter than the other 3 sides so the panel
                // hugs the last visible row (badges when no tier is
                // picked yet, or the Request Ride button after one is).
                // Otherwise the 14px equal-all-around padding leaves a
                // visible empty band below the badges in the no-pick state.
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
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

                  // Grabber — also the sheet's drag handle
                  // (2026-08-22 redesign). The sheet has two snapped states:
                  // expanded (every tier listed) and collapsed (only the
                  // picked tier's card plus the action panel, so the map
                  // and the route stay in view). Pull down to collapse,
                  // pull up — or tap — to bring the list back. Snaps on
                  // release; the height change animates inside the list,
                  // and the camera refits off _sheetHeightPx as always.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (option == null) return;
                      HapticService.selectionClick();
                      _syncCameraWithSheetToggle(
                          collapsing: !_sheetCollapsed,
                          tierCount: _displayTierCount);
                      _setState(() => _sheetCollapsed = !_sheetCollapsed);
                    },
                    onVerticalDragEnd: (d) {
                      if (option == null) return;
                      final v = d.primaryVelocity ?? 0;
                      if (v > 120 && !_sheetCollapsed) {
                        HapticService.selectionClick();
                        _syncCameraWithSheetToggle(
                            collapsing: true, tierCount: _displayTierCount);
                        _setState(() => _sheetCollapsed = true);
                      } else if (v < -120 && _sheetCollapsed) {
                        HapticService.selectionClick();
                        _syncCameraWithSheetToggle(
                            collapsing: false, tierCount: _displayTierCount);
                        _setState(() => _sheetCollapsed = false);
                      }
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Center(
                          child: Container(
                            width: 44,
                            height: 4,
                            margin: const EdgeInsets.only(bottom: 10),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        // No title (2026-08-24, Lyft-style): the list starts
                        // right under the handle. Only the Airport / 10% OFF
                        // pills keep this row when they apply.
                        if (_ctrl.state.isAirportTrip || widget.applyPromo)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (_ctrl.state.isAirportTrip)
                                _headerPill(
                                  icon: Icons.flight_rounded,
                                  text: S.of(context).airportLabel,
                                  color: const Color(0xFF4285F4),
                                ),
                              if (widget.applyPromo) ...[
                                if (_ctrl.state.isAirportTrip)
                                  const SizedBox(width: 8),
                                _headerPill(
                                  text: '10% OFF',
                                  color: const Color(0xFFE8C547),
                                ),
                              ],
                            ],
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),

                  // Vertical tier list (2026-08-22 redesign, Lyft-style).
                  //
                  // Every tier is a row. The picked one grows open in
                  // place — gold border, big car, capacity, price, the
                  // "in X min · H:MM" line and its description in a sunken
                  // sub-box — while the rest stay compact. Nothing swaps:
                  // each row animates its own size, so picking another
                  // tier reads as one card closing while the next opens.
                  //
                  // The cards are always drawn. A failed route, a missing
                  // endpoint and a fare call still in flight used to each
                  // swap the row for something else, and all three read to
                  // the rider as the app being broken. The tiers are known
                  // without any of it, so they stay, the money shows as a
                  // dash, and Select carries the fact that nothing can be
                  // booked yet.
                  // While the fares load the sheet shows Lyft-style
                  // skeleton cards (grey placeholder rows) — the real tiers
                  // crossfade in when the prices are ready (user spec
                  // 2026-08-24: the entry state must read as "loading",
                  // never as the old list popping in).
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: !faresReady &&
                            _ctrl.state.pickup != null &&
                            _ctrl.state.dropoff != null
                        ? _buildSkeletonTierRows()
                        : Column(
                            key: const ValueKey('tierRows'),
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final o in displayOptions)
                                _buildTierRow(
                                  c,
                                  o,
                                  option != null && o.id == option.id,
                                  // Collapsed sheet: only the picked card stays;
                                  // the rest fold away with the same animation.
                                  hidden: _sheetCollapsed &&
                                      option != null &&
                                      o.id != option.id,
                                ),
                            ],
                          ),
                  ),

                  // Under the list, not instead of it.
                  //
                  // Only when an endpoint is missing, because that is the one
                  // state waiting cannot resolve: the fares are computed from
                  // the two ends, so with one absent there is nothing on its
                  // way. A fare call still in flight says nothing here — the
                  // dashes already say it, and they go away on their own.
                  if (!faresReady &&
                      (_ctrl.state.pickup == null ||
                          _ctrl.state.dropoff == null)) ...[
                    const SizedBox(height: 4),
                    _buildMissingEndpointNotice(),
                  ],

                  // ── Action panel ── FLAT on the sheet's own background
                  // (2026-08-24, Lyft-style): payment method at the left,
                  // Schedule at the right, and the big gold
                  // "Select {tier}" button beneath. Only once a tier is
                  // picked — before that the sheet is just the list.
                  if (option != null)
                    _buildActionPanel(c, option, faresReady),
                  ],
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

  List<Widget> _buildFloatingLabels() {
    final s = _ctrl.state;
    final widgets = <Widget>[];
    final loc = S.of(context);
    final pickupText = loc.pickupUpperLabel; // "RECOGIDA" / "PICKUP"
    final dropoffText = loc.dropoffUpperLabel; // "DESTINO" / "DROPOFF"

    // Label geometry — the pill sits beside the pin's head, with clear
    // air between them, vertically centred on the head.
    //
    // The pin bitmap is 80×73.6 (GoldenPinPainter: _width = size,
    // _height = size * 0.92, size = radius*2+16 with radius 32) drawn at
    // iconSize 0.85 with iconAnchor BOTTOM — so the screen offset we get
    // from pixelForCoordinate is the pin's TIP, not its head. The head
    // centre sits at w * 0.34 from the bitmap top (GoldenPinPainter's
    // cupCY), i.e. ~63% of the pin height above the tip. These two
    // numbers are the ones to nudge if the pill reads high or low.
    const double pinOnScreenHalfWidth = 28.0;
    const double pinHeadLift = 34.0; // head centre above the tip
    // Air between pin and pill — practically touching (user spec
    // 2026-08-04, third iteration: "al lado de los pines, no separado").
    const double sideGap = 6.0;
    // Pill height is deterministic: 5px padding top/bottom + the taller
    // of the 19px icon chip and the kind+address stack (~22px), + border.
    const double pillHeight = 34.0;
    const double pillHalfHeight = pillHeight / 2;
    const double pillEstimatedWidth = 170.0; // icon+gap+maxWidth(130)+padding

    // Trip minutes pickup→dropoff for the gold box glued to the dropoff
    // label. Traffic-aware seconds first; the formatted "11 min" /
    // "1 h 5 min" text as fallback.
    String? etaMinutes;
    final route = s.route;
    if (route != null) {
      final secs = route.durationSeconds;
      int? mins = (secs != null && secs > 0)
          ? (secs / 60).round().clamp(1, 24 * 60)
          : null;
      if (mins == null) {
        final h = RegExp(r'(\d+)\s*h').firstMatch(route.durationText);
        final m = RegExp(r'(\d+)\s*min').firstMatch(route.durationText);
        if (h != null || m != null) {
          mins = (int.tryParse(h?.group(1) ?? '') ?? 0) * 60 +
              (int.tryParse(m?.group(1) ?? '') ?? 0);
        }
      }
      if (mins != null && mins > 0) etaMinutes = '$mins';
    }
    // The ETA box adds ~38px to the dropoff pill.
    final double dropoffPillWidth =
        pillEstimatedWidth + (etaMinutes != null ? 38.0 : 0.0);

    // Map viewport bounds so we can clamp the label inside the visible area.
    final mq = MediaQuery.of(context);
    final screenW = mq.size.width;
    final screenH = mq.size.height;
    // Reserve space for top notch + estimated bottom sheet so the
    // label never paints on top of UI chrome.
    final topSafe = mq.padding.top + 12;
    final bottomSafe = screenH * 0.55; // sheet covers bottom ~45%

    final pickupPos = _pickupScreenOffset;
    if (pickupPos != null && s.pickupLabel.isNotEmpty) {
      double left = pickupPos.dx + pinOnScreenHalfWidth + sideGap;
      final bool flipLeft = left + pillEstimatedWidth > screenW - 8;
      if (flipLeft) {
        left =
            pickupPos.dx - pinOnScreenHalfWidth - sideGap - pillEstimatedWidth;
      }
      // Clamp inside the viewport (left/right + top/bottom).
      left = left.clamp(8.0, screenW - pillEstimatedWidth - 8.0);
      // Centre on the pin HEAD: lift off the tip, then half the pill.
      double top = pickupPos.dy - pinHeadLift - pillHalfHeight;
      top = top.clamp(topSafe, bottomSafe - pillHeight);
      widgets.add(
        Positioned(
          left: left,
          top: top,
          child: AnimatedMapLabel(
            kind: MapLabelKind.pickup,
            address: s.pickupLabel,
            pickupText: pickupText,
            dropoffText: dropoffText,
            visible: _pickupLabelRevealed,
            alignEnd: flipLeft,
          ),
        ),
      );
    }

    final dropoffPos = _dropoffScreenOffset;
    if (dropoffPos != null && s.dropoffLabel.isNotEmpty) {
      double left =
          dropoffPos.dx - pinOnScreenHalfWidth - sideGap - dropoffPillWidth;
      final bool flipRight = left < 8;
      if (flipRight) {
        left = dropoffPos.dx + pinOnScreenHalfWidth + sideGap;
      }
      // Clamp inside the viewport.
      left = left.clamp(8.0, screenW - dropoffPillWidth - 8.0);
      double top = dropoffPos.dy - pinHeadLift - pillHalfHeight;
      top = top.clamp(topSafe, bottomSafe - pillHeight);
      widgets.add(
        Positioned(
          left: left,
          top: top,
          child: AnimatedMapLabel(
            kind: MapLabelKind.dropoff,
            address: s.dropoffLabel,
            pickupText: pickupText,
            dropoffText: dropoffText,
            visible: _dropoffLabelRevealed,
            alignEnd: !flipRight,
            etaMinutes: etaMinutes,
          ),
        ),
      );
    }
    return widgets;
  }

  /// One tier row in the choose-a-vehicle list (2026-08-22 redesign).
  ///
  /// Compact when not picked: small car on the left, name over its
  /// "in X min", price at the right edge. Picked, it grows open — rounded
  /// gold border, big car, capacity, the "in X min · H:MM AM/PM" line and
  /// the tier's description in a sunken sub-box. All of it through
  /// AnimatedSize / AnimatedContainer (~280 ms easeInOutCubic), so picking
  /// another tier reads as one card closing while the next opens, never a
  /// snap. [hidden] folds the row to nothing — the collapsed sheet keeps
  /// only the picked card — with the same animation instead of a
  /// disappearance.
  /// Lyft-style loading state: four grey skeleton rows standing in for the
  /// tiers while the fares are being computed (circle + two bars each).
  Widget _buildSkeletonTierRows() {
    Widget bar(double w, {double h = 12, double opacity = 0.10}) =>
        Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: opacity),
            borderRadius: BorderRadius.circular(h / 2),
          ),
        );
    Widget row() => Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.045),
            borderRadius: BorderRadius.circular(16),
            border:
                Border.all(color: Colors.white.withValues(alpha: 0.07)),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [bar(74), const SizedBox(height: 7), bar(48)],
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [bar(56, h: 14), const SizedBox(height: 7), bar(40)],
              ),
            ],
          ),
        );
    return Column(
      key: const ValueKey('tierSkeletons'),
      mainAxisSize: MainAxisSize.min,
      children: [row(), row(), row(), row()],
    );
  }

  /// Single source of truth for the tier display name used by the sheet
  /// (rows AND the "Select {tier}" button — before 2026-08-24 the button
  /// read TierInfo.displayTitle, the legacy VIP/Premium/Comfort naming).
  /// Lyft-style casing: first letter only ("Black", not "BLACK").
  static String _tierDisplayName(RideOption opt) {
    final isSuv = opt.id == 'suburban';
    final isFusion = opt.id == 'fusion';
    final isSuvXl = opt.id == 'suv_xl';
    final isPremium = !isSuv && !isSuvXl && !isFusion;
    return isSuv
        ? 'Black'
        : isSuvXl
            ? 'Premium'
            : (isPremium ? 'Compact' : 'Standard');
  }

  Widget _buildTierRow(AppColors c, RideOption opt, bool selected,
      {bool hidden = false}) {
    final promo = _promoPrice(opt);
    final String displayName = _tierDisplayName(opt);

    // Compact line under the name: "in 5 min". Placeholder tiers carry no
    // ETA (0), so they fall back to the cached per-tier wait range.
    final String waitText = opt.etaMinutes > 0
        ? S.of(context).inMinEta(opt.etaMinutes)
        : _gridWaitRangeText(_tierKeyForOption(opt));

    final priceStyle = TextStyle(
      fontFamily: 'Poppins',
      color: Colors.white,
      fontSize: selected ? 20 : 15,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.3,
    );

    return AnimatedSize(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 220),
        opacity: hidden ? 0.0 : 1.0,
        child: hidden
            // Zero-height but full-width, so AnimatedSize folds the row
            // away vertically without the list jumping sideways.
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: EdgeInsets.only(bottom: selected ? 10 : 4),
                child: _PressableScale(
                  onTap: () {
                    HapticService.selectionClick();
                    if (selected) {
                      // Collapsed sheet: tapping the lone card pulls the
                      // full list back up.
                      if (_sheetCollapsed) {
                        _syncCameraWithSheetToggle(
                            collapsing: false, tierCount: _displayTierCount);
                        _setState(() => _sheetCollapsed = false);
                      }
                      return;
                    }
                    _ctrl.selectRideOption(opt);
                    _refitRouteAfterPick();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeInOutCubic,
                    padding: EdgeInsets.symmetric(
                        horizontal: 12, vertical: selected ? 16 : 10),
                    decoration: BoxDecoration(
                      color: selected ? neuSurface : Colors.transparent,
                      borderRadius: BorderRadius.circular(18),
                      // Lyft-style: compact rows are FLAT on the sheet — no
                      // box, no border. Only the picked tier gets the card.
                      border: Border.all(
                        color: selected
                            ? const Color(0xFFE8C547).withValues(alpha: 0.7)
                            : Colors.transparent,
                        width: selected ? 1.6 : 0.0,
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            // The car grows with the card — AnimatedContainer
                            // eases the box, the render just fills it.
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 280),
                              curve: Curves.easeInOutCubic,
                              width: selected ? 108 : 60,
                              height: selected ? 72 : 42,
                              child: CarImage3D(
                                assetPath: _carAssetForOption(opt.name),
                                cacheWidth: 640,
                                alignment: Alignment.center,
                                fallback: Icon(
                                  Icons.directions_car_rounded,
                                  color: const Color(0xFFE8C547)
                                      .withValues(alpha: 0.5),
                                  size: 30,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Flexible(
                                        child: Text(
                                          displayName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontFamily: 'Poppins',
                                            color: Colors.white,
                                            fontSize: selected ? 16 : 14,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 0.4,
                                          ),
                                        ),
                                      ),
                                      if (selected) ...[
                                        const SizedBox(width: 8),
                                        Icon(
                                          Icons.person_rounded,
                                          size: 14,
                                          color: Colors.white
                                              .withValues(alpha: 0.65),
                                        ),
                                        const SizedBox(width: 2),
                                        Text(
                                          '${opt.capacity}',
                                          style: TextStyle(
                                            fontFamily: 'Poppins',
                                            color: Colors.white
                                                .withValues(alpha: 0.65),
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  // Compact rows carry the wait under the
                                  // name; once the card opens, the clock
                                  // line moves under the price, right-aligned
                                  // (2026-08-24, Lyft layout).
                                  if (!selected && waitText.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      waitText,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontFamily: 'Poppins',
                                        color: Colors.white
                                            .withValues(alpha: 0.55),
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                // Price crossfades dash → real fare instead
                                // of popping.
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 250),
                                  child: Text(
                                    promo.priceText,
                                    key: ValueKey(
                                        'tierPrice_${opt.id}_${promo.priceText}'),
                                    style: priceStyle,
                                  ),
                                ),
                                // Lyft layout: the "in X min · H:MM" line
                                // sits right under the price, plain grey —
                                // no icon chip (2026-08-24).
                                if (selected && _tierEtaLine(opt).isNotEmpty) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    _tierEtaLine(opt),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      fontFamily: 'Poppins',
                                      color:
                                          Colors.white.withValues(alpha: 0.55),
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                        // Expanded-only section: arrival clock + description
                        // sub-box. AnimatedSize grows it open; the opacity
                        // keeps the texts from popping in mid-travel.
                        AnimatedSize(
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeInOutCubic,
                          alignment: Alignment.topCenter,
                          child: selected
                              ? _buildTierExpandedDetail(c, opt)
                              : const SizedBox(width: double.infinity),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  /// The part of a picked tier's card that only exists while it is open:
  /// the tier's description as a full-width bar at the bottom of the card
  /// (Lyft's "A nicer ride, guaranteed" slot). The clock line lives up in
  /// the header, under the price.
  Widget _buildTierExpandedDetail(AppColors c, RideOption opt) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: neuBox(radius: 12, pressed: true),
          child: Text(
            _tierDescription(opt),
            style: TextStyle(
              fontFamily: 'Poppins',
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  /// "in 5 min · 3:42 PM" for the expanded card. In scheduled mode the
  /// wait is meaningless — the reservation has its own clock, and that is
  /// what the line shows. Empty when there is nothing honest to say
  /// (placeholder tier, no schedule).
  String _tierEtaLine(RideOption opt) {
    final sched = _ctrl.state.scheduledAt ?? widget.scheduledAt;
    if (sched != null) return _fmtClock(sched);
    if (opt.etaMinutes <= 0) return '';
    final eta = DateTime.now().add(Duration(minutes: opt.etaMinutes));
    return '${S.of(context).inMinEta(opt.etaMinutes)} · ${_fmtClock(eta)}';
  }

  /// "3:42 PM" — no intl DateFormat: the project never calls
  /// initializeDateFormatting, and 12h AM/PM is what both languages show.
  String _fmtClock(DateTime t) {
    final h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final mm = t.minute.toString().padLeft(2, '0');
    final ampm = t.hour < 12 ? 'AM' : 'PM';
    return '$h12:$mm $ampm';
  }

  /// The tier's own description when it carries one (the real options
  /// from the controller do); short bilingual fallbacks otherwise.
  String _tierDescription(RideOption opt) {
    if (opt.description.trim().isNotEmpty) return opt.description;
    final s = S.of(context);
    switch (opt.id) {
      case 'suburban':
        return s.tierDescBlack;
      case 'suv_xl':
        return s.tierDescPremium;
      case 'camry':
        return s.tierDescCompact;
      default:
        return s.tierDescStandard;
    }
  }

  /// Action panel (2026-08-24, Lyft-style): FLAT on the sheet's own
  /// background — no separate floating card, no shadow. Payment method at
  /// the left (same picker, same logos, same navigation), Schedule at the
  /// right, and the big gold "Select {tier}" button beneath, separated
  /// from the list by a hairline. Lives INSIDE the sheet container, so
  /// _SheetSizeReporter keeps measuring sheet+panel exactly as before.
  /// Grows in with AnimatedSize the first time a tier is picked.
  Widget _buildActionPanel(AppColors c, RideOption option, bool faresReady) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 4),
          // Hairline between the tier list and the action block.
          Container(height: 1, color: Colors.white.withValues(alpha: 0.05)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: _PaymentMethodButton(
                  onTap: () => _showPaymentMethodPicker(c, option),
                  selectedMethod: _selectedPaymentMethod,
                  logoBuilder: _paymentLogoWidget,
                  labelBuilder: _paymentLabel,
                ),
              ),
              const SizedBox(width: 8),
              _buildScheduleButton(),
            ],
          ),
          // Hairline divider between the payment row and the button
          // (rule-18 idiom).
          Container(height: 1, color: Colors.white.withValues(alpha: 0.05)),
          const SizedBox(height: 10),
          _WebRequestButton(
            // Nobody within fifteen miles means there is nothing to
            // request. Better to show it disabled than to take the
            // request and leave the rider watching a search that was
            // never going to find anyone. Only a confirmed zero disables
            // it — an unknown count leaves the button live. Only an
            // IMMEDIATE request is gated on drivers being around: a
            // reservation goes to the scheduled marketplace (2026-08-17).
            // And not before the fares are real, or Cruise Cash comes up
            // short of the FULL fare (user spec 2026-08-04).
            enabled: !_isProcessingPayment &&
                _hasAnyPaymentMethod &&
                (_isScheduledMode || !_noDriversNearby) &&
                faresReady &&
                !_cruiseCashShort(option),
            isLoading: _isProcessingPayment,
            // "Select {tier}" (2026-08-22): the button no longer pays
            // inline — it opens the pickup-pin page first, and the SAME
            // payment pipeline runs from there. The label crossfades on
            // every tier change inside the button itself.
            label:
                S.of(context).selectTierLabel(_tierDisplayName(option)),
            onTap: () {
              HapticService.mediumImpact();
              _openPickupConfirm(c, option);
            },
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  /// Calendar pill on the right of the payment row — opens the schedule
  /// wheels without leaving the booking.
  Widget _buildScheduleButton() {
    return GestureDetector(
      onTap: _openScheduleFromSheet,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: neuBox(radius: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.calendar_month_rounded,
              size: 16,
              color: const Color(0xFFE8C547).withValues(alpha: 0.9),
            ),
            const SizedBox(width: 6),
            Text(
              S.of(context).scheduleLabel,
              style: const TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Schedule button: the SAME Depart/Arrive wheels page the hub chain
  /// uses, pushed on top of this sheet with the endpoints prefilled — so
  /// the booking underneath is never rebuilt. The page pops back with the
  /// picked time and the sheet updates in place: _isScheduledMode reads
  /// _ctrl.state.scheduledAt, the expanded card swaps its ETA line for the
  /// scheduled clock, and the no-drivers gate lifts, all on the next
  //  frame. No flicker, no second RideRequestScreen.
  Future<void> _openScheduleFromSheet() async {
    HapticService.selectionClick();
    final st = _ctrl.state;
    final dropoff = st.dropoff;
    if (dropoff == null) return;
    final pickup = st.pickup;
    final secs = st.route?.durationSeconds;
    final record =
        await Navigator.of(context).push<(DateTime, Map<String, dynamic>)?>(
      slideUpFadeRoute(ScheduleDateTimeScreen(
        initialPickupLat: pickup?.lat,
        initialPickupLng: pickup?.lng,
        initialDateTime: st.scheduledAt ?? widget.scheduledAt,
        // The wheels show the real drop-off/pickup clock times when they
        // have the trip's minutes; without a route they omit those lines
        // rather than guessing.
        estimatedMinutes: (secs != null && secs > 0) ? (secs / 60).ceil() : null,
        prefilledPickup: pickup,
        prefilledDropoff: dropoff,
        prefilledPickupLabel: st.pickupLabel,
        prefilledDropoffLabel:
            st.dropoffLabel.isNotEmpty ? st.dropoffLabel : dropoff.address,
      )),
    );
    if (record == null || !mounted) return;
    final (scheduledAt, _) = record;
    _ctrl.setSchedule(scheduledAt);
    _setState(() {});
  }

  /// True when Cruise Cash is the selected method but the balance does
  /// not cover this option's (promo-adjusted) fare — the Request/Reserve
  /// button is disabled in that state instead of letting a request start
  /// that no method can pay for.
  bool _cruiseCashShort(RideOption opt) {
    if (_selectedPaymentMethod != 'cruise_cash') return false;
    final double price =
        widget.applyPromo ? opt.priceEstimate * 0.9 : opt.priceEstimate;
    return _cruiseCashCents < (price * 100).round();
  }

  /// Gap between the sheet and the screen's bottom edge: 24 px while the
  /// panel floats (no tier picked yet), 0 once picking a tier makes it go
  /// flush. Mirrors the `floating` rule in _buildRoutePreviewSheet.
  double get _sheetScreenGap {
    final s = _ctrl.state;
    final flush = widget.fastRide || s.selectedOption != null;
    return flush ? 0 : 24;
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
    final parts = text.split(_whitespaceRe);
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
    // Same three pre-cropped renders as the home "Choose a ride" cards.
    final key = name.trim().toLowerCase();
    if (key.contains('suv xl')) return 'assets/images/cruisert_suvxl.png';
    if (key.contains('vip') || key.contains('suburban')) return 'assets/images/cruisert1.png';
    // The camry tier shows as COMPACT, so it carries the compact SUV render
    // rather than the sedan one. Matched on the internal name, which is still
    // 'Sedan' — the ids never move, only what the rider is shown.
    if (key.contains('sedan') || key.contains('camry')) return 'assets/images/cruisert_compact.png';
    return 'assets/images/cruisert3.png';
  }

  /// Promo / Cruise Cash price math for an option — ONE source for the
  /// expanded card and the detail panel.
  ///
  /// The panel used to render the raw estimate while dispatch charged the
  /// discounted fare: the rider saw $25 and paid $20. A surprise in the
  /// rider's favour is still a surprise — both surfaces show the same
  /// numbers now.
  ///
  /// Promo math: when the rider entered through the 10% off button,
  /// widget.applyPromo is true and the rendered price is 90% of the
  /// estimate. We keep the original priceEstimate visible (struck
  /// through, smaller, gray) so they SEE the discount being applied.
  /// Cruise Cash preview: capped at $50/ride and never below 0. Backend
  /// re-applies the same math at dispatch time, so what the rider sees
  /// here is what they'll be charged.
  ({double basePrice, double finalPrice, bool priceKnown, String priceText, String oldPriceText})
      _promoPrice(RideOption opt) {
    final double basePrice = opt.priceEstimate;
    final double promoPrice = widget.applyPromo ? basePrice * 0.9 : basePrice;
    final double ccApplied = (_cruiseCashCents / 100.0)
        .clamp(0.0, 50.0)
        .clamp(0.0, promoPrice);
    final double finalPrice =
        (promoPrice - ccApplied).clamp(0.0, double.infinity);
    // Zero means the fares have not landed. A dash, never "$0.00".
    final bool priceKnown = basePrice > 0;
    return (
      basePrice: basePrice,
      finalPrice: finalPrice,
      priceKnown: priceKnown,
      priceText: priceKnown ? '\$${finalPrice.toStringAsFixed(2)}' : '—',
      oldPriceText: priceKnown ? '\$${basePrice.toStringAsFixed(2)}' : '—',
    );
  }

  /// The tier key the wait-estimate endpoint filters by, from a ride
  /// option — the SAME mapping the grid tiles use, so the selected card,
  /// the Faster badge and the tiles always ask the same question.
  String _tierKeyForOption(RideOption opt) {
    switch (opt.id) {
      case 'suburban':
        return 'black';
      case 'suv_xl':
        return 'premium';
      case 'fusion':
        return 'standard';
      default:
        return 'compact';
    }
  }

  /// Wait range for the small tier cards. Cache-only: these build on every
  /// frame of the collapse animation, and a build must never start network
  /// work. The expanded card's FutureBuilder is what fetches it — per tier
  /// now, because "who takes Black" and "who takes Standard" are different
  /// answers to the same pickup.
  String _gridWaitRangeText(String tier) {
    final pickup = _ctrl.state.pickup;
    if (pickup == null) return '';
    final est = DriverWaitEstimate.cached(pickup.lat, pickup.lng, tier: tier);
    if (est == null) {
      // Nothing cached for THIS tier — so ask. The request is shared and
      // cached for 15 s, so the four tiles cause four calls, one each, not
      // one per frame.
      unawaited(
        DriverWaitEstimate.fetch(lat: pickup.lat, lng: pickup.lng, tier: tier)
            .then((_) {
          _setState(() {});
        }),
      );
      return '';
    }
    // Grid tiles carry ONLY each tier's distance estimate (user spec
    // 2026-08-04) — an empty line when that tier has nobody out there.
    // The "no drivers near your area" sentence belongs to the SELECTED
    // card, where there is room for it to be an answer.
    if (est.driverCount == 0) return '';
    return est.rangeLabel;
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
                          durationLabel(opt.etaMinutes),
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
                    opt.priceEstimate > 0
                    ? '\$${opt.priceEstimate.toStringAsFixed(2)}'
                    : '—',
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

  /// True only when the server has confirmed there is nobody in range.
  ///
  /// Reads the cache rather than fetching: the wait widget above has
  /// already asked for this pickup, and the answer is shared. A build must
  /// never start network work — it runs many times per gesture.
  bool get _noDriversNearby {
    final pickup = _ctrl.state.pickup;
    if (pickup == null) return false;
    final est = DriverWaitEstimate.cached(pickup.lat, pickup.lng);
    return est != null && est.driverCount == 0;
  }

  /// True when this booking is for LATER (scheduled ride or airport trip),
  /// not an immediate dispatch. Reads from BOTH widget params (set at push
  /// time) and controller state (mutable — flips when an inline schedule
  /// picker fires _ctrl.setSchedule on the already-mounted screen).
  ///
  /// A reservation needs NO driver online right now: it goes to the
  /// scheduled marketplace where drivers claim it ahead of time, with the
  /// auto-dispatcher as backup. So the "no drivers nearby" gate and the
  /// wait-time line only apply to immediate requests.
  bool get _isScheduledMode =>
      widget.scheduledAt != null ||
      widget.isAirportTrip ||
      _ctrl.state.scheduledAt != null ||
      _ctrl.state.isAirportTrip;

  /// Re-frame the map on the route after the rider picks a tier.
  ///
  /// Delayed past the card animation so the fit is computed against the
  /// sheet height it is settling into, not the one it is leaving — fitting
  /// mid-collapse frames the route for a panel that is about to be a
  /// different size.
  void _refitRouteAfterPick() {
    if (_mapCtrl == null || _cinematicRunning) return;
    final st = _ctrl.state;
    if (st.pickup == null || st.dropoff == null) return;
    final pts = st.route?.points ??
        [
          LatLng(st.pickup!.lat, st.pickup!.lng),
          LatLng(st.dropoff!.lat, st.dropoff!.lng),
        ];
    Future.delayed(const Duration(milliseconds: 480), () {
      if (mounted && !_cinematicRunning) {
        _fitRoute(pts, preserveCamera: true);
      }
    });
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

  /// Shimmer placeholder card - horizontal layout
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
        return Container(
          height: 110,
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1F),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFFE8C547).withValues(alpha: 0.2),
              width: 1.5,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Car placeholder
                Container(
                  width: 100,
                  height: 80,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    gradient: gradient,
                  ),
                ),
                const SizedBox(width: 16),
                // Text placeholders
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Badge placeholder
                      Container(
                        width: 60,
                        height: 20,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          gradient: gradient,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Name placeholder
                      Container(
                        width: 100,
                        height: 16,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          gradient: gradient,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Description placeholder
                      Container(
                        width: 150,
                        height: 12,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(3),
                          gradient: gradient,
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

  /// The four tiers with everything the route decides left out.
  ///
  /// Ids and names match what [_generateRideOptions] builds, because the same
  /// card widgets read them to pick the badge, the label and the car. A price
  /// of zero is the signal for "not known yet" — every place that prints money
  /// checks for it and prints a dash instead.
  List<RideOption> _placeholderTiers() => const [
        RideOption(
          id: 'suburban',
          name: 'VIP',
          description: 'Spacious • Leather • Snacks & Drinks',
          priceEstimate: 0,
          etaMinutes: 0,
          icon: '🚐',
          capacity: 7,
        ),
        RideOption(
          id: 'suv_xl',
          name: 'SUV XL',
          description: 'Up to 6 • XL luggage • Climate',
          priceEstimate: 0,
          etaMinutes: 0,
          icon: '🚙',
          capacity: 6,
        ),
        RideOption(
          id: 'camry',
          name: 'Sedan',
          description: 'Comfort • Climate • Charger',
          priceEstimate: 0,
          etaMinutes: 0,
          icon: '🚙',
          capacity: 4,
        ),
        RideOption(
          id: 'fusion',
          name: 'Comfort',
          description: 'Clean • Safe • Efficient',
          priceEstimate: 0,
          etaMinutes: 0,
          icon: '🚗',
          capacity: 4,
        ),
      ];

  /// Why the sheet has no cards, when waiting cannot produce any.
  ///
  /// The fares are worked out from the two endpoints, so with one of them
  /// missing there is nothing to compute and nothing to wait for. The rider
  /// needs to be told which end is missing and given the control that fixes
  /// it, not a loading state that never ends.
  Widget _buildMissingEndpointNotice() {
    final st = _ctrl.state;
    final needsPickup = st.pickup == null;
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
            needsPickup
                ? S.of(context).setPickupOnMap
                : S.of(context).whereTo,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () {
              HapticService.selectionClick();
              _ctrl.startLocationSelection();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE8C547)),
              ),
              child: Text(
                S.of(context).chooseOnMap,
                style: const TextStyle(
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Recenter, welded directly above this card instead of
              // anchored to _sheetHeightPx — that height still held the
              // choose-a-vehicle sheet here, which parked the button in the
              // middle of the map, nowhere near the card it belongs to.
              // Outside the reporter below, so the camera's bottom inset
              // keeps measuring the card alone.
              Padding(
                padding: const EdgeInsets.only(right: 2, bottom: 12),
                child: _circleButton(
                  icon: Icons.my_location_rounded,
                  onTap: _recenterMap,
                  c: c,
                ),
              ),
              _SheetSizeReporter(
            onChanged: _onSheetHeightChanged,
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
                  color: Colors.black,
                ),
                child: Stack(
                  children: [
                    // Floating gold particles background — same idea as
                    // SearchingDriverScreen, just scoped to this card.
                    Positioned.fill(
                      child: IgnorePointer(
                        child: AnimatedBuilder(
                          animation: _radarCtrl,
                          builder: (_, __) => CustomPaint(
                            painter: _SearchingCardParticlesPainter(
                              t: _radarCtrl.value,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
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
                                      // 48×48 logo circle — Cruise app brand mark
                                      Container(
                                        width: 48,
                                        height: 48,
                                        decoration: BoxDecoration(
                                          color: Colors.black,
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
                                        child: const ClipOval(
                                          child: Image(
                                            image: AssetImage(
                                                'assets/images/logoapp.png'),
                                            fit: BoxFit.cover,
                                            width: 48,
                                            height: 48,
                                          ),
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
      case 'cruise_cash':
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: const Color(0xFFE8C547).withValues(alpha: 0.5),
                width: 1),
          ),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Image.asset(
              'assets/images/cruise_logo.png',
              fit: BoxFit.contain,
              cacheWidth: 80,
            ),
          ),
        );
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
              // No map of its own — the overlay used to mount a second
              // full-screen Mapbox surface here while the base map was
              // swapped for a black box (two live surfaces crash iOS).
              // The surface never finished initialising inside the
              // overlay's 1.8s lifetime, so the rider saw pure black
              // instead of "driver found" (user report 2026-08-04).
              // The scrim below now sits over the LIVE main map, whose
              // camera _dfFlyMainCamera() fits to the whole route.
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
                        // Raised neumorphic card (shared system — see
                        // neu_style.dart), keeping the faint gold halo that
                        // marks this as the moment the driver was matched.
                        decoration: neuBox(
                          radius: 20,
                          borderColor: gold.withValues(alpha: 0.2),
                        ).copyWith(
                          boxShadow: [
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
                                // Sunken well — the plate reads as stamped
                                // into the card, same idiom as the driver's
                                // own trip screen.
                                decoration: neuBox(
                                  radius: 8,
                                  pressed: true,
                                  borderColor: gold.withValues(alpha: 0.3),
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
    // Pressed neumorphic circle (same language as the other back buttons).
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: neuBox(radius: 14, pressed: true),
        alignment: Alignment.center,
        child: Icon(icon, size: 20, color: Colors.white),
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
      // No card around this row — user spec 2026-08-04: the selector sits
      // flat on the sheet, just icon + label + chevron. The press feedback
      // that the neu box used to carry is now a simple opacity dip.
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: _pressed ? 0.6 : 1.0,
        child: Container(
        width: double.infinity,
        color: Colors.transparent, // keeps the whole row tappable
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        child: Row(
          children: [
            // Icon in a pressed neumorphic well — the Apple / Google /
            // Card / Test Mode graphics stay identical to the picker.
            Container(
              width: 40,
              height: 40,
              decoration: neuBox(radius: 12, pressed: true),
              alignment: Alignment.center,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: SizedBox(
                  key: ValueKey('payLogo_${widget.selectedMethod}'),
                  child: widget.logoBuilder(widget.selectedMethod, 26),
                ),
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
              // Gold CTA — solid, with a soft gold shadow.
              color: const Color(0xFFE8C547),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFE8C547).withValues(alpha: 0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
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
                // The label changes with the tier ("Select Standard" →
                // "Select Black") — fade+slide between them instead of a
                // snap (user spec 2026-08-22).
                : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.25),
                          end: Offset.zero,
                        ).animate(anim),
                        child: child,
                      ),
                    ),
                    child: Text(
                      widget.label,
                      key: ValueKey(widget.label),
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
  const _PressableScale({super.key, required this.child, required this.onTap});

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


// ═══════════════════════════════════════════════════════════════════════
//  Subtle gold particle painter for the "Searching nearby drivers" card.
//  Lightweight version of SearchingDriverScreen particles — fewer dots,
//  scoped to the card bounds, slow drift for ambient feel.
// ═══════════════════════════════════════════════════════════════════════
class _SearchingCardParticlesPainter extends CustomPainter {
  final double t; // 0→1 loop driver
  _SearchingCardParticlesPainter({required this.t});

  // Pre-baked particle seeds (fixed positions + sizes + phase offsets) so
  // the layout is stable across rebuilds.
  static const List<List<double>> _seeds = [
    [0.08, 0.20, 1.6, 0.0],
    [0.18, 0.72, 1.0, 0.4],
    [0.27, 0.42, 1.4, 0.7],
    [0.36, 0.85, 0.9, 0.2],
    [0.45, 0.30, 1.2, 0.5],
    [0.54, 0.55, 1.6, 0.8],
    [0.62, 0.18, 1.1, 0.3],
    [0.70, 0.66, 1.3, 0.6],
    [0.78, 0.34, 0.9, 0.1],
    [0.86, 0.78, 1.5, 0.9],
    [0.92, 0.45, 1.0, 0.4],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    for (final s in _seeds) {
      final px = s[0] * size.width;
      final py = s[1] * size.height;
      final r = s[2];
      final phase = s[3];
      // Twinkle: 0→1→0 over the loop, offset per particle.
      final phaseT = ((t + phase) % 1.0);
      final twinkle = phaseT < 0.5 ? phaseT * 2 : (1.0 - phaseT) * 2;
      final alpha = (0.10 + 0.35 * twinkle).clamp(0.0, 1.0);
      // Slight horizontal drift.
      final dx = math.sin((t + phase) * 2 * math.pi) * 4;
      paint.color = const Color(0xFFE8C547).withValues(alpha: alpha);
      canvas.drawCircle(Offset(px + dx, py), r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SearchingCardParticlesPainter old) =>
      old.t != t;
}

// ═══════════════════════════════════════════════════════════════════
//  Real silhouette drop shadow for vehicle PNGs.
//  Renders a black-tinted copy of the asset behind the original,
//  offset slightly down + blurred. Follows the exact outline of the
//  vehicle (windows, mirrors, wheels) so the shadow looks like an
//  actual cast shadow instead of a generic ellipse beneath the car.
// ═══════════════════════════════════════════════════════════════════
class _CarWithDropShadow extends StatelessWidget {
  final String asset;
  final double width;
  final double height;

  const _CarWithDropShadow({
    required this.asset,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height + 10, // extra room for the shadow to spill below
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // Shadow layer: same PNG, tinted black, offset down + blurred.
          Positioned(
            top: 8,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4),
              child: ColorFiltered(
                colorFilter: ColorFilter.mode(
                  Colors.black.withValues(alpha: 0.55),
                  BlendMode.srcIn,
                ),
                child: Image.asset(
                  asset,
                  width: width,
                  height: height,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
          // Original car on top.
          Image.asset(
            asset,
            width: width,
            height: height,
            fit: BoxFit.contain,
          ),
        ],
      ),
    );
  }
}

/// Reports its child's rendered height after every layout change.
///
/// Same pattern as the driver's offer-card `_SizeReporter`, but height-only:
/// the ride sheet never changes width, and the camera fit / address bar only
/// care about how much vertical space the panel eats.
class _SheetSizeReporter extends StatefulWidget {
  const _SheetSizeReporter({required this.onChanged, required this.child});

  final ValueChanged<double> onChanged;
  final Widget child;

  @override
  State<_SheetSizeReporter> createState() => _SheetSizeReporterState();
}

class _SheetSizeReporterState extends State<_SheetSizeReporter> {
  double? _reported;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        // The notification carries no size — read it after the frame.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final h = context.size?.height;
          if (h == null || h == _reported) return;
          _reported = h;
          widget.onChanged(h);
        });
        return true;
      },
      child: SizeChangedLayoutNotifier(child: widget.child),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  "Faster" badge — selected tier card, nearest FREE driver ≤ 5 min
// ═══════════════════════════════════════════════════════════════════

/// Gold pill with a hand-painted steering wheel, top-right of the selected
/// tier card. Silky by construction: it lands with an overshoot pop
/// (easeOutBack scale + fade) and then breathes — a slow 2.4 s glow/scale
/// sine loop, subtle enough to feel alive without shouting.
class FasterBadge extends StatefulWidget {
  const FasterBadge({super.key});

  @override
  State<FasterBadge> createState() => _FasterBadgeState();
}

class _FasterBadgeState extends State<FasterBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breathe;

  @override
  void initState() {
    super.initState();
    _breathe = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Entrance: one-shot pop.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 480),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Transform.scale(
        scale: 0.6 + 0.4 * t,
        child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
      ),
      child: AnimatedBuilder(
        animation: _breathe,
        builder: (context, child) {
          // No box at all — user spec 2026-08-04: just the gold word and
          // the gold wheel. The breathing lives in a soft glow around the
          // glyphs themselves plus a barely-there scale.
          final s = math.sin(_breathe.value * 2 * math.pi);
          final glow = 0.35 + 0.25 * s;
          final scale = 1.0 + 0.02 * s;
          return Transform.scale(
            scale: scale,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CustomPaint(
                    painter: _SteeringWheelPainter(
                      color: const Color(0xFFE8C547),
                      glow: glow,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  // Product copy by request — the same word in both languages.
                  'Faster',
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                    color: const Color(0xFFF5D990),
                    shadows: [
                      Shadow(
                        color: const Color(0xFFE8C547)
                            .withValues(alpha: glow),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Minimal steering wheel: rim, three spokes at 90°/210°/330°, hub.
/// Material has no steering-wheel glyph — 20 lines of canvas beat a wrong
/// metaphor. Gold, with a breathing glow behind the strokes.
class _SteeringWheelPainter extends CustomPainter {
  const _SteeringWheelPainter({
    this.color = const Color(0xFFE8C547),
    this.glow = 0.0,
  });

  final Color color;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 0.8;
    if (glow > 0) {
      final gp = Paint()
        ..color = color.withValues(alpha: glow * 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3);
      canvas.drawCircle(c, r, gp);
    }
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(c, r, p);
    for (final deg in [90.0, 210.0, 330.0]) {
      final a = deg * math.pi / 180;
      canvas.drawLine(
        c + Offset(math.cos(a), math.sin(a)) * 2.2,
        c + Offset(math.cos(a), math.sin(a)) * (r - 0.6),
        p,
      );
    }
    canvas.drawCircle(c, 1.6, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SteeringWheelPainter oldDelegate) =>
      oldDelegate.glow != glow || oldDelegate.color != color;
}
