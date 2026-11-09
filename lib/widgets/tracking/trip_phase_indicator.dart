part of '../../screens/rider_tracking_screen.dart';

// ════════════════════════════════════════════════════════════
//  TRIP PHASE INDICATOR — destination box with phase status
// ════════════════════════════════════════════════════════════

extension _RiderTrackingPhaseIndicator on _RiderTrackingScreenState {

  // ── Format ETA for display: ≤60 → "45 min", >60 → "1h 15min" ──
  String get _etaDisplayText {
    if (_etaMinutes <= 0) return '0';
    if (_etaMinutes < 60) return '$_etaMinutes';
    final hours = _etaMinutes ~/ 60;
    final mins = _etaMinutes % 60;
    if (mins == 0) return '${hours}h';
    return '${hours}h ${mins}min';
  }

  String get _etaUnitText {
    if (_etaMinutes <= 0) return 'min';
    if (_etaMinutes < 60) return 'min';
    return ''; // unit is embedded in _etaDisplayText for hour format
  }

  // ── Phase-based dot color ──
  Color get _dotColor {
    switch (_phase) {
      case _TrackPhase.arriving:
        final distM = _distanceMiles * 1609.34;
        // Shift from gold → orange as driver gets close. Stay orange (not red)
        // until the backend explicitly transitions to 'arrived' phase.
        if (_etaMinutes <= 2 || distM <= 300) return const Color(0xFFFF9500); // orange: arriving
        return const Color(0xFFFFD700);                   // gold: on the way
      case _TrackPhase.arrived:
        return const Color(0xFF2196F3); // Blue — driver llegó al pickup
      case _TrackPhase.onTrip:
        return const Color(0xFFFFD700); // Golden — en camino al destino
      case _TrackPhase.nearDestination:
        return const Color(0xFFFFD700); // Golden — llegando
      case _TrackPhase.completed:
        return const Color(0xFF4CAF50);  // Green — trip completed
    }
  }

  // ── Phase-based single status text (for arrived / onTrip brief / nearDestination) ──
  String get _singleStatusText {
    final s = S.of(context);
    switch (_phase) {
      case _TrackPhase.arriving:
        return ''; // not used in single mode
      case _TrackPhase.arrived:
        return s.driverHasArrived;
      case _TrackPhase.onTrip:
        return _tripJustStarted ? s.tripStartedTitle : s.onWayToDestination;
      case _TrackPhase.nearDestination:
        return s.arrivingAtDestination;
      case _TrackPhase.completed:
        return s.tripCompletedTitle;
    }
  }

  // ── Destination + ETA box (floats at bottom) ──
  Widget _buildDestinationBox() {
    final Color dotColor = _dotColor;

    // The guide at the top (owner 2026-11-03, drawing J6zTb8hfeKDqfFbzpx5jXb):
    // 1. arriving → "Tu conductor llega en 7 min · Llega a las 3:42 PM"
    // 2. arrived → "Tu conductor llegó", one line
    // 3. onTrip + _tripJustStarted → "Your trip has started", one line
    // 4. onTrip / nearDestination → "Llegas a tu destino en 12 min · 4:05 PM"
    Widget content;
    if (_phase == _TrackPhase.arriving) {
      content = _buildArrivingContent(dotColor);
    } else if (_phase == _TrackPhase.arrived) {
      content = _buildArrivedContent(dotColor);
    } else if (_phase == _TrackPhase.onTrip && _tripJustStarted) {
      content = _buildSingleLineContent(dotColor, false);
    } else if (_phase == _TrackPhase.completed) {
      // Trip finished — single centered text, no ETA badge
      content = _buildSingleLineContent(dotColor, false);
    } else {
      // onTrip (steady) or nearDestination — show dropoff ETA
      content = _buildOnTripContent(dotColor);
    }

    // A reservation still ahead: its pickup time under the guide, gold —
    // the driver set off an hour early and may be here well before it.
    final resAt = _reservationAt;
    if (resAt != null &&
        (_phase == _TrackPhase.arriving || _phase == _TrackPhase.arrived) &&
        DateTime.now().isBefore(resAt)) {
      content = Column(
        key: ValueKey('guide_reserved_${content.key}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          content,
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('guide-reservation-pickup'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFE8C547).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: const Color(0xFFE8C547).withValues(alpha: 0.45)),
            ),
            child: Text(
              S.of(context).pickupAtClock(
                  TimeOfDay.fromDateTime(resAt).format(context)),
              style: const TextStyle(
                color: Color(0xFFE8C547),
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      );
    }

    // Dark glass like the sheet below it: the map blurs behind, nothing
    // behind it reads.
    return GlassSurface(
      borderRadius: BorderRadius.circular(22),
      blur: kGlassSheetBlurOpen,
      tint: glassSheetOpenTint,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 500),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, anim) =>
            FadeTransition(opacity: anim, child: child),
        child: content,
      ),
    );
  }

  /// "7 min", or "1h 15min" past the hour.
  String get _etaBigText => _etaMinutes < 60
      ? S.of(context).trackMinutes(_etaMinutes)
      : _etaDisplayText;

  /// The clock time the ETA lands on, in the phone's own format ("3:42 PM",
  /// "15:42").
  String get _etaClockText => TimeOfDay.fromDateTime(
          DateTime.now().add(Duration(minutes: _etaMinutes)))
      .format(context);

  /// The two-sided guide: "<lead> / 7 min" on the left, "<clockLead> /
  /// 3:42 PM" in gold on the right. The minutes roll in place as they count
  /// down; the row itself never swaps.
  Widget _buildEtaGuide({
    required String tag,
    required Color dotColor,
    required String lead,
    required String clockLead,
  }) {
    return Row(
      key: ValueKey('guide_$tag'),
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                lead,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.65),
                  fontSize: 13,
                ),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.3),
                      end: Offset.zero,
                    ).animate(anim),
                    child: child,
                  ),
                ),
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.centerLeft,
                  children: [...previous, if (current != null) current],
                ),
                child: Text(
                  _etaBigText,
                  key: ValueKey('eta_$_etaMinutes'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              clockLead,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 12,
              ),
            ),
            Text(
              _etaClockText,
              style: const TextStyle(
                color: AppColors.kGold,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// One centered line: "Tu conductor llegó", "Tu conductor está llegando",
  /// "Llegando a tu destino".
  Widget _buildGuideLine(String text, Color dotColor, {bool pulse = false}) {
    final dot = Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
    );
    return Row(
      key: ValueKey('line_$text'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (pulse)
          ScaleTransition(
            scale: Tween<double>(begin: 0.7, end: 1.3).animate(_arrivedDotPulse),
            child: dot,
          )
        else
          dot,
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }

  /// Arriving: the live countdown to the pickup and the clock time it lands.
  Widget _buildArrivingContent(Color dotColor) {
    final s = S.of(context);
    final distM = _distanceMiles * 1609.34;
    if (_etaMinutes <= 0 || distM <= 50) {
      return _buildGuideLine(s.trackDriverAlmostThere, dotColor);
    }
    return _buildEtaGuide(
      tag: 'arriving',
      dotColor: dotColor,
      lead: s.trackDriverArrivesIn,
      clockLead: s.trackArrivesAt,
    );
  }

  /// Arrived / OnTrip / NearDestination: single centered text, no ETA badge
  Widget _buildSingleLineContent(Color dotColor, bool isArrivedState) {
    final text = _singleStatusText;

    return Row(
      key: ValueKey('single_$_phase'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Pulsing dot for arrived, static dot for others
        if (isArrivedState)
          ScaleTransition(
            scale: Tween<double>(begin: 0.7, end: 1.3)
                .animate(_arrivedDotPulse),
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dotColor,
              ),
            ),
          )
        else
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dotColor,
            ),
          ),
        const SizedBox(width: 12),
        Flexible(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            transitionBuilder: (child, anim) =>
                FadeTransition(opacity: anim, child: child),
            child: Text(
              text,
              key: ValueKey(text),
              style: TextStyle(
                color: isArrivedState ? const Color(0xFFC8A951) : Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }

  /// Arrived: "Tu conductor llegó" the moment the driver taps "Llegué".
  Widget _buildArrivedContent(Color dotColor) =>
      _buildGuideLine(S.of(context).trackDriverArrived,
          const Color(0xFF4ADE80),
          pulse: true);

  /// OnTrip / NearDestination: the countdown to the destination and the
  /// clock time; one line once there.
  Widget _buildOnTripContent(Color dotColor) {
    final s = S.of(context);
    final distM = _distanceMiles * 1609.34;
    if (_etaMinutes <= 0 || distM <= 200) {
      return _buildGuideLine(s.arrivingAtDestination, dotColor);
    }
    return _buildEtaGuide(
      tag: 'ontrip',
      dotColor: dotColor,
      lead: s.trackYouArriveIn,
      clockLead: s.trackYouArriveAt,
    );
  }

  /// The two map buttons (owner 2026-11-03, drawing J6zTb8hfeKDqfFbzpx5jXb),
  /// right side, just above the resting sheet:
  /// - the arrow, "Seguir" — always there; gold while it leads the camera;
  /// - the zigzag, "Ruta completa" — fades in once the camera is following
  ///   (or the rider moved the map) and fades out when tapped, back on the
  ///   whole trip.
  Widget _buildMapButtons() {
    final s = S.of(context);
    final following = _camFollow && !_userControllingCamera;
    final showFull = _camFollow || _userControllingCamera;
    Widget button({
      required Key key,
      required String label,
      required Widget icon,
      required VoidCallback onTap,
      bool active = false,
    }) {
      return Semantics(
        button: true,
        label: label,
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: () {
            HapticService.selectionClick();
            onTap();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: active ? AppColors.kGold : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: MapChipSurface(
              circle: true,
              width: 46,
              height: 46,
              child: Center(child: icon),
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        IgnorePointer(
          ignoring: !showFull,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeInOut,
            opacity: showFull ? 1 : 0,
            child: AnimatedScale(
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeOutCubic,
              scale: showFull ? 1 : 0.85,
              child: button(
                key: const ValueKey('map-full-route'),
                label: s.trackFullRoute,
                icon: Transform.rotate(
                  angle: 1.5708,
                  child: const Icon(Icons.route_rounded,
                      color: Colors.white, size: 22),
                ),
                onTap: () => _setCameraFollow(false),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        button(
          key: const ValueKey('map-follow'),
          label: s.trackFollow,
          active: following,
          icon: Icon(Icons.navigation_rounded,
              color: following ? AppColors.kGold : Colors.white, size: 22),
          onTap: () => _setCameraFollow(true),
        ),
      ],
    );
  }

  Widget _buildConnectionLostBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFE8C547),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              S.of(context).connectionLost,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
