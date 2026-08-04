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
          child: AnimatedContainer(
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
            child: SafeArea(
              top: false,
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
              // is sometimes taller than intended is a smaller problem than a
              // button nobody can reach — but anything added below must be
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

                  // .vipRide__pricesHeader — centered title row with
                  // optional Airport / 10% OFF pills to the side.
                  // Title is Flexible + ellipsis so it truncates instead
                  // of overflowing when both pills are active on narrow
                  // screens (iPhone SE with airport + promo).
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Back to the full picker.
                      //
                      // Takes no room when there is nothing to go back to:
                      // an arrow that is always there but only sometimes
                      // does anything is worse than one that appears when it
                      // means something. Sized rather than removed so the
                      // title does not shift sideways as it comes and goes.
                      SizedBox(
                        width: 32,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 420),
                          curve: Curves.easeInOutCubic,
                          opacity: (option != null && !_gridExpanded) ? 1 : 0,
                          child: IgnorePointer(
                            ignoring: option == null || _gridExpanded,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                HapticService.selectionClick();
                                _setState(() => _gridExpanded = true);
                              },
                              child: const Icon(
                                Icons.arrow_back_rounded,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Flexible(
                        child: Text(
                          widget.fastRide
                              ? S.of(context).fastRideLabel
                              : S.of(context).chooseARide,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Poppins',
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            letterSpacing: -0.6, // -.03em × 20px
                          ),
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
                      // Mirrors the back arrow's width so the title stays
                      // optically centred whether the arrow is showing or
                      // not — otherwise it slides sideways on every
                      // selection.
                      const SizedBox(width: 32),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Grid of ride cards - 1:1 with web design.
                  // Behavior: when no tier is picked OR the rider tapped the
                  // selected card to expand again, show all 3 cards. After a
                  // pick, collapse to ONLY the chosen card so the bottom
                  // sheet feels lighter and the focus stays on the choice.
                  // The cards are always drawn. Nothing replaces them.
                  //
                  // A failed route, a missing endpoint and a fare call still
                  // in flight used to each swap the row for something else,
                  // and all three read to the rider as the app being broken.
                  // The tiers are known without any of it, so they stay, the
                  // money shows as a dash, and Request Ride carries the fact
                  // that nothing can be booked yet.
                  //
                  // A missing endpoint is still worth a word, since waiting
                  // will not fix it — it goes under the cards now instead of
                  // in place of them.
                    // One row that reshapes, not two views that swap.
                    //
                    // It used to crossfade between "three cards" and "one
                    // card" — which reads as a replacement, not as a choice
                    // being made. Here the cards never leave the row: the
                    // ones not chosen shrink their width to nothing while
                    // fading, and because they are laid out left to right,
                    // the chosen card is carried leftward by their collapse.
                    // The movement is the layout, so it cannot desync from
                    // the fade the way two separate animations would.
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(
                        begin: (option != null && !_gridExpanded) ? 1 : 0,
                        end: (option != null && !_gridExpanded) ? 1 : 0,
                      ),
                      // Slow enough to be watched, eased at both ends.
                      //
                      // 460 ms on a curve that starts at full speed made the
                      // row snap and then coast — the movement was over
                      // before the eye had followed it, which is what reads
                      // as abrupt no matter how smooth the interpolation is.
                      // Material's emphasized easing accelerates gently and
                      // settles gently, so the cards look like they have
                      // weight rather than being teleported and decelerated.
                      duration: const Duration(milliseconds: 680),
                      curve: Curves.easeInOutCubicEmphasized,
                      builder: (context, t, _) {
                        return LayoutBuilder(
                          builder: (context, box) {
                            final n = displayOptions.length;
                            const gap = 8.0;
                            // An unbounded width poisons every number below
                            // it. `full` feeds each card's width through
                            // lerpDouble, and lerping to infinity gives NaN,
                            // which a RenderBox rejects — the row then throws
                            // during layout and Flutter leaves that subtree
                            // blank while the title above it draws normally.
                            // Which is a booking sheet with a heading and
                            // nothing under it.
                            //
                            // A Row inside a horizontally unbounded parent is
                            // not exotic, and the fallback only has to be
                            // finite to keep the cards on screen.
                            final raw = box.maxWidth;
                            final full = (raw.isFinite && raw > 0) ? raw : 360.0;
                            // Width of one card when all of them are shown.
                            final each = n > 0
                                ? (full - gap * (n - 1)) / n
                                : full;
                            // Height follows width, so the card keeps its
                            // shape as tiers are added. Held at a fixed 120
                            // it went from nearly square at three tiers to
                            // tall and narrow at four — the card looked
                            // stretched, which is the one thing it must not
                            // look. Capped so three tiers keep today's size.
                            final cardH = (each * 1.10).clamp(84.0, 120.0);
                            final selIdx = option == null
                                ? -1
                                : displayOptions
                                    .indexWhere((o) => o.id == option.id);

                            // An empty sheet, and this is how it happened.
                            //
                            // At t=1 exactly one card is meant to grow to the
                            // full width while the rest shrink to nothing. The
                            // one that grows is picked by `i == selIdx` — so if
                            // selIdx is -1, nothing matches, every card takes
                            // the shrinking branch, and all of them animate to
                            // zero. The rider gets "Choose a vehicle" over a
                            // blank panel with no way out.
                            //
                            // selIdx is -1 whenever the selected option is not
                            // in the list being drawn, which is not exotic:
                            // fastRide swaps displayOptions for a single
                            // comfort_express card while selectedOption still
                            // holds whatever was picked before, and a selection
                            // made against one route survives into the next.
                            //
                            // No match means nothing is selected, so draw the
                            // full row. Losing the collapse animation for one
                            // frame is not a bug the rider can see; an empty
                            // booking sheet is the whole screen.
                            final tt = selIdx < 0 ? 0.0 : t;

                            // Bounded height, or nothing here gets painted.
                            //
                            // This builder is handed maxHeight: Infinity, and
                            // each card sits in an OverflowBox, which takes
                            // the largest size its constraints allow — so it
                            // asked to be infinitely tall. A RenderBox cannot
                            // have an infinite size, layout threw, and Flutter
                            // left the whole row blank while the heading above
                            // it drew normally.
                            //
                            // The cards were built the entire time. Their
                            // build-time logs fired with the right names and
                            // the right 95.7 px height; it was the layout pass
                            // after that died, which is why the sheet looked
                            // like it had no data when it had all of it.
                            //
                            // cardH is what the cards are already sized to, so
                            // giving the row that height changes nothing about
                            // how it looks — it only stops the constraint from
                            // being unbounded.
                            return SizedBox(
                              height: cardH,
                              child: Row(
                              children: [
                                for (int i = 0; i < n; i++) ...[
                                  if (i == selIdx)
                                    // Grows into the space the others leave.
                                    SizedBox(
                                      width: ui.lerpDouble(each, full, tt),
                                      child: _PressableScale(
                                        onTap: () {
                                          HapticService.selectionClick();
                                          _setState(() => _gridExpanded = !_gridExpanded);
                                        },
                                        // The two layouts cross-fade, and the
                                        // height eases between them.
                                        //
                                        // This used to be a bare ternary on
                                        // t > 0.5, so halfway through an
                                        // otherwise smooth 680 ms slide the
                                        // card's contents were replaced in a
                                        // single frame — and its height
                                        // jumped with them. Going back it was
                                        // worse: the big "5 - 20 min" on the
                                        // right vanished mid-travel. The
                                        // width was always animating; it was
                                        // everything else that snapped.
                                        child: AnimatedSize(
                                          duration:
                                              const Duration(milliseconds: 680),
                                          curve:
                                              Curves.easeInOutCubicEmphasized,
                                          alignment: Alignment.topCenter,
                                          child: AnimatedSwitcher(
                                            duration: const Duration(
                                                milliseconds: 300),
                                            switchInCurve: Curves.easeOut,
                                            switchOutCurve: Curves.easeIn,
                                            // Stacked, so the outgoing layout
                                            // keeps its place while it fades
                                            // instead of collapsing and
                                            // shoving the incoming one.
                                            layoutBuilder: (current, previous) =>
                                                Stack(
                                              alignment: Alignment.topLeft,
                                              children: [
                                                ...previous,
                                                if (current != null) current,
                                              ],
                                            ),
                                            child: t > 0.5
                                                ? KeyedSubtree(
                                                    key: const ValueKey('wide'),
                                                    child:
                                                        _buildRideHorizontalCard(
                                                            c,
                                                            displayOptions[i]),
                                                  )
                                                : KeyedSubtree(
                                                    key: const ValueKey('tile'),
                                                    child:
                                                        _buildRideOptionCardGrid(
                                                            c,
                                                            displayOptions[i],
                                                            height: cardH),
                                                  ),
                                          ),
                                        ),
                                      ),
                                    )
                                  else
                                    // Folds away. Clipped so its contents do
                                    // not spill while the width closes.
                                    SizedBox(
                                      width: ui.lerpDouble(each, 0, tt),
                                      child: ClipRect(
                                        child: Opacity(
                                          // Gone by two-thirds of the way,
                                          // so the last third is pure
                                          // movement with nothing dissolving
                                          // over it. Fading and travelling
                                          // at once for the whole duration
                                          // is what makes a transition look
                                          // busy instead of calm.
                                          opacity: (1 - t * 1.55).clamp(0.0, 1.0),
                                          child: OverflowBox(
                                            maxWidth: each,
                                            minWidth: each,
                                            alignment: Alignment.centerLeft,
                                            child: _PressableScale(
                                              onTap: () {
                                                HapticService.selectionClick();
                                                _ctrl.selectRideOption(
                                                    displayOptions[i]);
                                                _setState(() =>
                                                    _gridExpanded = false);
                                                _refitRouteAfterPick();
                                              },
                                              child: _buildRideOptionCardGrid(
                                                c,
                                                displayOptions[i],
                                                height: cardH,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (i < n - 1)
                                    SizedBox(width: ui.lerpDouble(gap, 0, tt)!),
                                ],
                              ],
                              ),
                            );
                          },
                        );
                      },
                    ),

                  // Under the cards, not instead of them.
                  //
                  // Only when an endpoint is missing, because that is the one
                  // state waiting cannot resolve: the fares are computed from
                  // the two ends, so with one absent there is nothing on its
                  // way. A fare call still in flight says nothing here — the
                  // dashes already say it, and they go away on their own.
                  if (!faresReady &&
                      (_ctrl.state.pickup == null ||
                          _ctrl.state.dropoff == null)) ...[
                    const SizedBox(height: 10),
                    _buildMissingEndpointNotice(),
                  ],

                  // .vipRide__rideDetail — appears only when the rider
                  // re-expanded the grid (so they can compare detail
                  // while picking). In collapsed mode the horizontal
                  // card already shows stats and price.
                  // Shown in both states now. It used to appear only while
                  // the picker was open, because the collapsed card had
                  // swallowed those figures into itself — and the collapsed
                  // card is now the tier and its wait, nothing else. The
                  // rider should not have to reopen the picker to see the
                  // price they are about to pay.
                  if (option != null) ...[
                    const SizedBox(height: 10),
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
                        // Nobody within fifteen miles means there is nothing
                        // to request. Better to show it disabled than to
                        // take the request and leave the rider watching a
                        // search that was never going to find anyone.
                        //
                        // Only a confirmed zero disables it — an unknown
                        // count (the server did not answer) leaves the
                        // button live, because a network hiccup is not the
                        // same as an empty city.
                        // And not before the fares are real. The cards are
                        // drawn from placeholders when the route has not
                        // produced any, so without this the rider could send
                        // a request against a tier priced at nothing.
                        enabled: !_isProcessingPayment &&
                            _hasAnyPaymentMethod &&
                            !_noDriversNearby &&
                            faresReady,
                        isLoading: _isProcessingPayment,
                        // "Reserve Now" for both scheduled rides AND
                        // airport bookings (both go through pre-pickup
                        // confirmation flow). "Request Ride" only for
                        // immediate dispatch from the home Where-to.
                        //
                        // Reads from BOTH widget params (set at push
                        // time) and controller state (mutable — flips
                        // when an inline schedule picker fires
                        // _ctrl.setSchedule). Without the controller
                        // check, picking a future date AFTER the screen
                        // is already mounted leaves the label stuck on
                        // "Request Ride".
                        label: (widget.scheduledAt != null ||
                                widget.isAirportTrip ||
                                _ctrl.state.scheduledAt != null ||
                                _ctrl.state.isAirportTrip)
                            ? S.of(context).bookScheduledRide
                            : S.of(context).requestRide,
                        onTap: () {
                          HapticService.mediumImpact();
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
        ),
      );
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

  // Horizontal ride card - 1:1 with web design
  // Badge top-left, 3D car image with shadow, description right side
  Widget _buildRideOptionCard(AppColors c, RideOption opt, bool selected) {
    final isSuv = opt.id == 'suburban';
    final isFusion = opt.id == 'fusion';
    final isSuvXl = opt.id == 'suv_xl';

    // SUV XL is priced above PREMIUM, so it carries the same black-and-gold
    // badge as BLACK rather than the silver one every non-matching id used
    // to fall into.
    final bool isVIP = isSuv || isSuvXl;
    final bool isPremium = !isVIP && !isFusion;
    final String tierLabel =
        isSuv ? 'VIP' : isSuvXl ? 'PREMIUM' : (isPremium ? 'COMPACT' : 'COMFORT');
    final String displayName =
        isSuv ? 'BLACK' : isSuvXl ? 'PREMIUM' : (isPremium ? 'COMPACT' : 'STANDARD');

    // Badge styles 1:1 with shopify-live-pull/sections/ride-request.liquid:142,764-770:
    //   VIP     → BLACK gradient (#1a1a1a→#000) + gold border, white text, diamond glyph
    //   PREMIUM → GOLD gradient  (#F5DC7A→#E8C547→#B08800), black text, star glyph
    //   COMFORT → SILVER gradient(#E8E8E8→#B0B0B0), near-black text, sparkle glyph
    final badgeGradient = isVIP
        ? const [Color(0xFF1A1A1A), Color(0xFF000000)]
        : isPremium
            ? const [Color(0xFFF5DC7A), Color(0xFFE8C547), Color(0xFFB08800)]
            : const [Color(0xFFE8E8E8), Color(0xFFB0B0B0)];
    final badgeTextColor = isVIP
        ? Colors.white
        : isPremium
            ? Colors.black
            : const Color(0xFF1A1A1A);
    // Badge glyphs 1:1 with web (live-pull line 142):
    //   VIP=💎(diamond)  PREMIUM=★  COMFORT=✦
    final IconData? badgeIcon = isVIP ? Icons.diamond : null;
    final String badgeGlyph = isPremium ? '★' : '✦';

    return AnimatedBuilder(
      animation: selected ? _activeCardGlowCtrl : kAlwaysDismissedAnimation,
      builder: (_, __) {
        final t = selected ? _activeCardGlowCtrl.value : 0.0;
        final glowAlpha = 0.15 + 0.15 * t;
        
        return Container(
          height: 110,
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1F), // Dark background
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? const Color(0xB3E8C547)
                  : const Color(0xFFE8C547).withValues(alpha: 0.2),
              width: selected ? 2 : 1.5,
            ),
            boxShadow: [
              // Gold ambient glow
              BoxShadow(
                color: const Color(0xFFE8C547).withValues(alpha: glowAlpha * 0.5),
                blurRadius: 30,
                spreadRadius: -5,
              ),
              // Inner glow when selected (using non-inset shadow as fallback)
              if (selected)
                BoxShadow(
                  color: const Color(0xFFE8C547).withValues(alpha: 0.15),
                  blurRadius: 8,
                  spreadRadius: 2,
                ),
            ],
          ),
          child: Stack(
            children: [
              // Content row
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    // Left side - Car image with 3D shadow
                    SizedBox(
                      width: 100,
                      height: 80,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // No plate behind the car: the black rounded box
                          // + gold blur used to read as a square overlay.
                          // The render carries its own look now.
                          // Car image
                          Image.asset(
                            _carAssetForOption(opt.name),
                            width: 90,
                            height: 70,
                            fit: BoxFit.contain,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    // Right side - Text content
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Badge in top — 1:1 with web (live-pull line 142,764-770)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: badgeGradient,
                              ),
                              borderRadius: BorderRadius.circular(6),
                              // VIP gets a thin gold border (web: 1px solid rgba(232,197,71,.3))
                              border: isVIP
                                  ? Border.all(
                                      color: const Color(0xFFE8C547).withValues(alpha: 0.3),
                                      width: 1,
                                    )
                                  : null,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (badgeIcon != null)
                                  Icon(badgeIcon, size: 10, color: badgeTextColor)
                                else
                                  Text(
                                    badgeGlyph,
                                    style: TextStyle(
                                      color: badgeTextColor,
                                      fontSize: 10,
                                      height: 1,
                                    ),
                                  ),
                                const SizedBox(width: 4),
                                Text(
                                  tierLabel,
                                  style: TextStyle(
                                    color: badgeTextColor,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          // Vehicle name
                          Text(
                            displayName,
                            style: const TextStyle(
                              fontFamily: 'Poppins',
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          // Description in gold
                          Text(
                            opt.description,
                            style: const TextStyle(
                              fontFamily: 'Poppins',
                              color: Color(0xFFE8C547),
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Floating gold-border labels ("RECOGIDA" / "DESTINO") that sit
  // beside each pin tip, matching the Shopify widget's .vipRide__mapLabel.
  // Positions are driven by _pickupScreenOffset / _dropoffScreenOffset
  // which are recomputed on every camera change via _syncLabelOffsets().
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
    const double sideGap = 10.0; // clear gap, pill never touches the pin
    // Pill height is deterministic: 5px padding top/bottom + the taller
    // of the 19px icon chip and the kind+address stack (~22px), + border.
    const double pillHeight = 34.0;
    const double pillHalfHeight = pillHeight / 2;
    const double pillEstimatedWidth = 170.0; // icon+gap+maxWidth(130)+padding

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
          dropoffPos.dx - pinOnScreenHalfWidth - sideGap - pillEstimatedWidth;
      final bool flipRight = left < 8;
      if (flipRight) {
        left = dropoffPos.dx + pinOnScreenHalfWidth + sideGap;
      }
      // Clamp inside the viewport.
      left = left.clamp(8.0, screenW - pillEstimatedWidth - 8.0);
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
          ),
        ),
      );
    }
    return widgets;
  }

  // Single card shown when a tier has been picked and the grid is
  // collapsed. One horizontal row: the small car render on the left, the
  // tier name plus the three sunken stat chips (ETA minutes, trip miles,
  // passenger capacity) in the middle, price pinned right.
  //
  // No tier badge and no description line — the chips carry the facts and
  // the card stays one compact row instead of the tall stacked block.
  Widget _buildRideHorizontalCard(AppColors c, RideOption opt) {
    final bool isSuv = opt.id == 'suburban';
    final bool isFusion = opt.id == 'fusion';
    final bool isSuvXl = opt.id == 'suv_xl';
    final bool isVIP = isSuv || isSuvXl;
    final bool isPremium = !isVIP && !isFusion;
    final String displayName =
        isSuv ? 'BLACK' : isSuvXl ? 'PREMIUM' : (isPremium ? 'COMPACT' : 'STANDARD');

    // Trip distance comes from the pickup→dropoff route (already
    // formatted in miles, e.g. "12.34 mi"). Em dash while the route is
    // still loading.
    final String distanceText = _ctrl.state.route?.distanceText ?? '— mi';

    // Promo math: when the rider entered through the 10% off button,
    // widget.applyPromo is true and the rendered price is 90% of the
    // estimate. We keep the original priceEstimate visible (struck
    // through, smaller, gray) so they SEE the discount being applied.
    final bool promoOn = widget.applyPromo;
    final double basePrice = opt.priceEstimate;
    final double promoPrice = promoOn ? basePrice * 0.9 : basePrice;
    // Cruise Cash preview: capped at $50/ride and never below 0. Backend
    // re-applies the same math at dispatch time, so what the rider sees
    // here is what they'll be charged.
    final double ccApplied = (_cruiseCashCents / 100.0)
        .clamp(0.0, 50.0)
        .clamp(0.0, promoPrice);
    final bool hasCC = ccApplied > 0;
    final double finalPrice = (promoPrice - ccApplied).clamp(0.0, double.infinity);
    // Zero means the fares have not landed. A dash, never "$0.00".
    final bool priceKnown = basePrice > 0;
    final String priceText =
        priceKnown ? '\$${finalPrice.toStringAsFixed(2)}' : '—';
    final String oldPriceText =
        priceKnown ? '\$${basePrice.toStringAsFixed(2)}' : '—';

    return Container(
      key: ValueKey('horizontal_${opt.id}'),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      // Raised neumorphic card on the sheet, thin gold edge marking it
      // as the selected tier.
      decoration: neuBox(
        radius: 24,
        borderColor: const Color(0xFFE8C547).withValues(alpha: 0.45),
      ),
      // Clipped, and explicitly.
      //
      // CarImage3D paints silhouette drop shadows and, when selected, a
      // blurred gold glow that reaches past the render's own box on
      // purpose. Inside a padded card that is fine.
      //
      // On Android's Impeller those ImageFiltered layers are not held by a
      // Container's decoration clip, so the glow ran out under the card's
      // rounded corner and read as the car hanging off the edge. iOS honours
      // the decoration clip, which is why it looked right there.
      //
      // A ClipRRect is a real clip layer and filters respect it. Same radius,
      // so the platform that was already correct does not move.
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── Left: tier name sitting directly above its car, the two
          // read as one unit. bottomCenter keeps the wheels planted no
          // matter how tall the source asset is.
          SizedBox(
            // 108 rather than 84, and the render 76 tall rather than 60.
            //
            // The car is the only picture on a card otherwise made of type,
            // and at 84 wide it was smaller than the words beside it — the
            // thing the rider actually recognises, losing to a label.
            width: 108,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayName,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 6),
                // Flexible, not fixed: the picker sheet caps the card row
                // (SizedBox(height: cardH), max 120) and the card's 28 px
                // of vertical padding leave ~92 px for this column — 12
                // short of the name + gap + 76 the car asks for, which is
                // the "BOTTOM OVERFLOWED BY 12 PIXELS" under the render.
                // Letting the image give those pixels back keeps the full
                // 76 wherever the row is unconstrained and only shrinks
                // the picture, never the words.
                Flexible(
                  child: SizedBox(
                  height: 76,
                  child: CarImage3D(
                    assetPath: _carAssetForOption(opt.name),
                    cacheWidth: 640,
                    // Centred in its box, not sitting on the floor of it.
                    //
                    // These renders are far wider than they are tall, so at
                    // 108 wide the car only fills about a third of a 76 px
                    // box. Anchored to the bottom it left all that space in
                    // one band under the tier name, which read as a gap in
                    // the card rather than as air around the car.
                    alignment: Alignment.center,
                    fallback: Icon(
                      Icons.directions_car_rounded,
                      color: const Color(0xFFE8C547).withValues(alpha: 0.5),
                      size: 32,
                    ),
                  ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),

          // ── Right: the wait, pushed to the far edge.
          //
          // The price used to sit out here, beside the same figure the panel
          // directly below already spells out — the same number twice on one
          // screen, in two type sizes. It stays in the panel with the miles,
          // the minutes and the seats. This side carries the one thing the
          // rider cannot work out for themselves: whether anyone is coming,
          // and roughly how soon.
          Expanded(
            child: Align(
              // Centred in the room to the right of the car, not shoved
              // against the card's edge.
              //
              // Hard right put "5 - 20 min" at 19 px flush with the padding,
              // where it read as clipped and had nowhere to go if the range
              // ever ran wider. Centring gives it air on both sides and
              // keeps it clear of the tier name on the left.
              child: _buildWaitEstimate(),
            ),
          ),
        ],
        ),
      ),
    );
  }

  // Detail panel shown below the 3-card grid once the user has picked a
  // tier. Sunken neumorphic well with the same three stat chips as the
  // collapsed card (ETA, trip miles, capacity) plus the big price — no
  // description line.
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
        decoration: neuBox(radius: 14, pressed: true),
        child: Row(
          children: [
            _neuStatChip(Icons.schedule_rounded, durationLabel(opt.etaMinutes)),
            const SizedBox(width: 6),
            _neuStatChip(Icons.route_rounded,
                _ctrl.state.route?.distanceText ?? '— mi'),
            const SizedBox(width: 6),
            _neuStatChip(Icons.person_rounded, '${opt.capacity}'),
            const Spacer(),
            if (_ctrl.state.route == null)
              _buildPriceShimmer(width: 68, height: 22)
            else
              // .vipRide__rideDetail__price: clamp(18,5vw,22)
              // weight 800 color #fff.
              Text(
                opt.priceEstimate > 0
                    ? '\$${opt.priceEstimate.toStringAsFixed(2)}'
                    : '—',
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
      ),
    );
  }

  // Grid card - 1:1 match with web design (3 columns)
  // Web CSS: .vipRide__rideCard grid version
  /// One tile in the four-up grid.
  ///
  /// Every tile looks the same, including the one currently chosen: no gold
  /// border, no sunken well. Picking a tier is answered by the row itself —
  /// the chosen card opens to full width and the others close — so marking
  /// it as well said the same thing twice and made one card look like it
  /// belonged to a different set.
  Widget _buildRideOptionCardGrid(AppColors c, RideOption opt,
      {double height = 120}) {
    final isSuv = opt.id == 'suburban';
    final isFusion = opt.id == 'fusion';
    final isSuvXl = opt.id == 'suv_xl';

    final bool isVIP = isSuv || isSuvXl;
    final bool isPremium = !isVIP && !isFusion;
    final String displayName =
        isSuv ? 'BLACK' : isSuvXl ? 'PREMIUM' : (isPremium ? 'COMPACT' : 'STANDARD');
    final String carAsset = _carAssetForOption(opt.name);

    // Same visual rhythm as the home fleet cards: name on top, car right
    // below it with a fixed height, comfortable padding all around — no
    // Expanded/Spacer, so there's no empty band in the middle.
    // Everything inside shrinks with the card, so four tiers read as four
    // smaller cards rather than four squeezed ones. Text has a floor —
    // scaling a 13 px label by 0.75 gives 9 px, which is not a smaller
    // label, it is an unreadable one.
    final s = (height / 120).clamp(0.70, 1.0);
    final pad = 10 * s;
    final carH = 46 * s;
    final nameSize = math.max(10.0, Responsive.vehicleNameSize * s);
    final waitSize = math.max(10.0, 11 * s);

    return Container(
      // Height comes from the caller, which derives it from how wide the
      // card ended up — see the cardH above. Every value here is spent
      // twice: the sheet is capped at 40% of the screen, so what the card
      // takes, the map does not get.
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: neuBox(radius: 24),
      child: Padding(
        padding: EdgeInsets.fromLTRB(8 * s, pad, 8 * s, pad),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Vehicle name on top — home screen style.
            //
            // Shrinks to fit rather than truncating. Four tiers share the
            // row now, so a card is about 80 px wide and "STANDARD" no
            // longer fits at full size — ellipsis would leave "STANDAR…",
            // which reads as a bug.
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                displayName,
                textAlign: TextAlign.center,
                maxLines: 1,
                style: TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white,
                  fontSize: nameSize,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            SizedBox(height: 8 * s),
            // Car render, centered. Shorter than the home fleet cards on
            // purpose: this sheet competes with the map for the screen.
            // Inset a little, so the car does not run edge to edge.
            //
            // Trimming the box height would do nothing: the render is 2.7
            // times wider than it is tall, so inside a card this narrow it
            // is the width that decides how big the car comes out, and
            // there is already spare height above and below it.
            SizedBox(
              height: carH,
              width: double.infinity,
              child: FractionallySizedBox(
                widthFactor: 0.88,
                child: CarImage3D(
                  assetPath: carAsset,
                  cacheWidth: 640,
                  alignment: Alignment.center,
                  fallback: Icon(
                    Icons.directions_car_rounded,
                    color: const Color(0xFFE8C547).withValues(alpha: 0.5),
                    size: 40,
                  ),
                ),
              ),
            ),
            // The wait, under the car. Just the range — per tier now,
            // because different tiers really have different drivers, and
            // one shared "2-4 min" for everyone was a number nobody
            // could trust.
            SizedBox(height: 5 * s),
            Text(
              _gridWaitRangeText(
                isSuv ? 'black' : isSuvXl ? 'premium' : (isPremium ? 'compact' : 'standard'),
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: waitSize,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
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
    if (est.driverCount == 0) return S.of(context).noDriversAvailable;
    return est.rangeLabel;
  }

  // Shimmer card for grid loading state - web style
  Widget _buildShimmerCardGrid({double height = 120}) {
    return Container(
      // Matches the real card, or the sheet visibly jumps the moment the
      // fares land and the skeletons are replaced.
      height: height,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0x0AFFFFFF),
            Color(0x05FFFFFF),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0x12FFFFFF),
          width: 1,
        ),
      ),
      child: const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            color: Color(0xFFE8C547),
            strokeWidth: 2,
          ),
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

  /// Small sunken neumorphic stat chip (icon + value) used on the
  /// collapsed tier card — inset well via the shared neu style.
  /// "5-20 min de espera", or the reason there is none.
  ///
  /// Reads the cached answer first so the card paints complete on the very
  /// frame the rider taps a tier — the count is per pickup point, not per
  /// vehicle, so switching between tiers can never need a new request. Only
  /// the first tap on a new pickup waits, and only for as long as one cached
  /// call takes.
  Widget _buildWaitEstimate() {
    final pickup = _ctrl.state.pickup;
    if (pickup == null) return const SizedBox.shrink();

    final cached = DriverWaitEstimate.cached(pickup.lat, pickup.lng);
    return FutureBuilder<WaitEstimate>(
      initialData: cached,
      future: DriverWaitEstimate.fetch(lat: pickup.lat, lng: pickup.lng),
      builder: (context, snap) {
        final est = snap.data;
        // Still asking. Deliberately blank rather than "0 min" or a spinner:
        // an empty space for a beat reads as loading, a number that then
        // changes reads as the app having lied.
        if (est == null) return const SizedBox(height: 34);

        final none = est.driverCount == 0;
        final text = none
            ? S.of(context).noDriversAvailable
            : est.rangeLabel;

        return AnimatedSwitcher(
          // Longer than the card's own move and eased the same way, so the
          // wait does not land while the card is still travelling — it
          // arrives into a card that has come to rest.
          duration: const Duration(milliseconds: 420),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.12, 0),
                end: Offset.zero,
              ).animate(anim),
              child: child,
            ),
          ),
          // One line: the range, then "of wait" beside it.
          //
          // It was stacked, which made a two-line block out of what is really
          // one phrase — and the second line, at 11 px under a 19 px figure,
          // read as a footnote to the number rather than part of it. Side by
          // side and closer in size, it reads as a sentence.
          //
          // Baseline-aligned, so the small word sits on the same line as the
          // digits instead of floating at their vertical centre.
          child: FittedBox(
            key: ValueKey('wait_${none}_$text'),
            fit: BoxFit.scaleDown,
            // Shrinks rather than ellipsing. "No drivers available" is a
            // sentence, not a number — cut to "No drivers av…" it stops
            // being an answer at all.
            child: Row(
              mainAxisSize: MainAxisSize.min,
              textBaseline: TextBaseline.alphabetic,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              children: [
                Text(
                  text,
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    color: none ? const Color(0xFFEF9A9A) : Colors.white,
                    fontSize: none ? 15 : 23,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    height: 1.1,
                  ),
                ),
                if (!none) ...[
                  const SizedBox(width: 6),
                  Text(
                    S.of(context).ofWait,
                    maxLines: 1,
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
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

  Widget _neuStatChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: neuBox(radius: 10, pressed: true),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              size: 13, color: const Color(0xFFE8C547).withValues(alpha: 0.85)),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Poppins',
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.80),
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
          child: _SheetSizeReporter(
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
              if (pickup != null && kIsWeb)
                // The native MapWidget has no web implementation — GL JS
                // takes over in the browser with the same route + pins.
                IgnorePointer(
                  child: RepaintBoundary(
                    child: WebMapView(
                      key: const ValueKey('driver_found_map_web'),
                      initialLng: midLng,
                      initialLat: midLat,
                      initialZoom: 14.5,
                      styleUri: MapboxConfig.styleDark,
                      onControllerCreated: (c) {
                        c.applyNavyGoldTheme();
                        c.hidePoiLayers();
                        final routePts = _ctrl.state.route?.points;
                        if (routePts != null && routePts.length >= 2) {
                          final pts = routePts
                              .map((p) => (lng: p.longitude, lat: p.latitude))
                              .toList();
                          c.setPolyline('route', pts,
                              color: '#FFD700', width: 5);
                        }
                        // Native holds the midpoint at 14.5 and eases the
                        // tilt 0→20° over 1 s — one GL JS flight does both.
                        c.flyTo(
                          lng: midLng,
                          lat: midLat,
                          zoom: 14.5,
                          pitch: 20,
                          durationMs: 1000,
                        );
                        // The golden pins, not GL JS's stock blue teardrop.
                        unawaited(Future(() async {
                          final pins = await Future.wait([
                            renderCircularPinBytes(
                                icon: CircularPinIcon.person,
                                isPickup: true,
                                radius: 32),
                            renderCircularPinBytes(
                                icon: _pinIconToCircular(
                                    _detectDropoffType(_ctrl.state.dropoffLabel)),
                                isPickup: false,
                                radius: 32),
                          ]);
                          if (!mounted) return;
                          c.addMarker('pickup', pickup.lng, pickup.lat,
                              iconBytes: pins[0],
                              widthPx: 52,
                              heightPx: 48,
                              anchor: 'bottom');
                          if (dropoff != null) {
                            c.addMarker('dropoff', dropoff.lng, dropoff.lat,
                                iconBytes: pins[1],
                                widthPx: 52,
                                heightPx: 48,
                                anchor: 'bottom');
                          }
                        }));
                      },
                    ),
                  ),
                )
              else if (pickup != null)
                IgnorePointer(
                  child: RepaintBoundary(
                    child: mapbox.MapWidget(
                      textureView: true,
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
                          final routeGeo = safeLineString(routePts);
                          if (routeGeo != null) {
                            await polyMgr.create(mapbox.PolylineAnnotationOptions(
                              geometry: routeGeo,
                              lineColor: const Color(0xFFFFD700).toARGB32(),
                              lineWidth: 5.0,
                              lineJoin: mapbox.LineJoin.ROUND,
                            ));
                          }
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
                        final pickupPoint = safePoint(pickup.lng, pickup.lat);
                        if (pickupPoint != null) {
                          await pointMgr.create(mapbox.PointAnnotationOptions(
                            geometry: pickupPoint,
                            image: pickupBytes,
                            iconSize: 0.65,
                            iconAnchor: mapbox.IconAnchor.BOTTOM,
                            iconOffset: [0, 0],
                          ));
                        }
                        if (dropoff != null) {
                          final dropoffBytes =
                              await renderCircularPinBytes(icon: CircularPinIcon.home, isPickup: false, radius: 44);
                          final dropoffPoint = safePoint(dropoff.lng, dropoff.lat);
                          if (dropoffPoint != null) {
                            await pointMgr.create(mapbox.PointAnnotationOptions(
                              geometry: dropoffPoint,
                              image: dropoffBytes,
                              iconSize: 0.65,
                              iconAnchor: mapbox.IconAnchor.BOTTOM,
                              iconOffset: [0, 0],
                            ));
                          }
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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: neuBox(radius: 16, pressed: _pressed),
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
