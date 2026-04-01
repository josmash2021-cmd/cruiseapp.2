part of '../../screens/rider_tracking_screen.dart';

// ════════════════════════════════════════════════════════════
//  TRIP PHASE INDICATOR — destination box with phase status
// ════════════════════════════════════════════════════════════

extension _RiderTrackingPhaseIndicator on _RiderTrackingScreenState {

  // ── Phase-based status text (top label) ──
  // During 'arriving', the label is refined by ETA and distance to show
  // progressively urgent messages as the driver gets closer.
  String get _topStatusText {
    final s = S.of(context);
    switch (_phase) {
      case _TrackPhase.arriving:
        // Distance in meters: _distanceMiles * 1609.34
        final distM = _distanceMiles * 1609.34;
        if (distM <= 50) return s.driverAtPickupSpot;                 // ≤50m: at spot
        if (_etaMinutes <= 2 || distM <= 300) return s.driverArrivingCard;  // ≤2min or ≤300m
        if (_etaMinutes <= 5) return s.driverAlmostHereCard;           // ≤5min
        return s.driverEnRoute;                                        // >5min
      case _TrackPhase.arrived:
        return s.driverHasArrived;
      case _TrackPhase.onTrip:
        return s.onWayToDestination;
      case _TrackPhase.nearDestination:
        return s.arrivingAtDestination;
      case _TrackPhase.completed:
        return s.tripCompletedTitle;
    }
  }

  // ── Phase-based bottom card text ──
  // Mirrors _topStatusText logic: smart sub-states for 'arriving' phase.
  String get _bottomCardText {
    final s = S.of(context);
    switch (_phase) {
      case _TrackPhase.arriving:
        final distM = _distanceMiles * 1609.34;
        if (distM <= 50) return s.driverWaitingAtPickup;              // ≤50m: waiting
        if (_etaMinutes <= 2 || distM <= 300) return s.driverArrivingCard;
        if (_etaMinutes <= 5) return s.driverAlmostHereCard;
        return s.driverOnTheWayCard;                                   // >5min
      case _TrackPhase.arrived:
        return s.driverWaitingForYou;
      case _TrackPhase.onTrip:
        return s.onWayToDestinationCard;
      case _TrackPhase.nearDestination:
        return s.arrivingAtDestinationCard;
      case _TrackPhase.completed:
        return s.tripCompletedTitle;
    }
  }

  // ── Phase-based dot color ──
  Color get _dotColor {
    switch (_phase) {
      case _TrackPhase.arriving:
        final distM = _distanceMiles * 1609.34;
        // Shift from gold → orange → red as driver gets very close
        if (distM <= 50) return const Color(0xFFEF4444);  // red: at spot
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

    // Determine which content to show:
    // 1. arriving → full row with status + ETA badge (pickup ETA)
    // 2. arrived → single centered text with pulsing dot
    // 3. onTrip + _tripJustStarted → single centered "Your trip has started"
    // 4. onTrip / nearDestination → row with status + ETA badge (dropoff ETA)
    Widget content;
    if (_phase == _TrackPhase.arriving) {
      content = _buildArrivingContent(dotColor);
    } else if (_phase == _TrackPhase.arrived) {
      content = _buildSingleLineContent(dotColor, true);
    } else if (_phase == _TrackPhase.onTrip && _tripJustStarted) {
      content = _buildSingleLineContent(dotColor, false);
    } else if (_phase == _TrackPhase.completed) {
      // Trip finished — single centered text, no ETA badge
      content = _buildSingleLineContent(dotColor, false);
    } else {
      // onTrip (steady) or nearDestination — show dropoff ETA
      content = _buildOnTripContent(dotColor);
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
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

  /// Arriving phase: dot + status label + bold text + ETA badge
  Widget _buildArrivingContent(Color dotColor) {
    final String topText = _topStatusText;
    final String bottomText = _bottomCardText;

    return Row(
      key: const ValueKey('arriving_content'),
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 500),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dotColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 400),
                      transitionBuilder: (child, anim) =>
                          FadeTransition(opacity: anim, child: child),
                      child: Text(
                        topText,
                        key: ValueKey(topText),
                        style: TextStyle(
                          color: dotColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.8,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: child),
                child: Text(
                  bottomText,
                  key: ValueKey(bottomText),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        // ETA badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$_etaMinutes',
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Text(
                'min',
                style: TextStyle(color: Colors.black54, fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ],
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

  /// OnTrip / NearDestination: status + ETA badge (dropoff ETA)
  Widget _buildOnTripContent(Color dotColor) {
    final String topText = _topStatusText;
    final String bottomText = _bottomCardText;

    return Row(
      key: ValueKey('ontrip_${_phase}_$_etaMinutes'),
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dotColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 400),
                      transitionBuilder: (child, anim) =>
                          FadeTransition(opacity: anim, child: child),
                      child: Text(
                        topText,
                        key: ValueKey(topText),
                        style: TextStyle(
                          color: dotColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.8,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: child),
                child: Text(
                  bottomText,
                  key: ValueKey(bottomText),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        // ETA badge (dropoff ETA)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$_etaMinutes',
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Text(
                'min',
                style: TextStyle(color: Colors.black54, fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildResumeButton() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Center(
        child: GestureDetector(
          onTap: _recenter,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: const Color(0xFFD4AF37).withValues(alpha: 0.4),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 8,
                ),
              ],
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.my_location_rounded, color: Color(0xFFD4AF37), size: 14),
                SizedBox(width: 6),
                Text('Resume', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
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
