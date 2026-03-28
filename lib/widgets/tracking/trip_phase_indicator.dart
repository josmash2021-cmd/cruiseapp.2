part of '../../screens/rider_tracking_screen.dart';

// ════════════════════════════════════════════════════════════
//  TRIP PHASE INDICATOR — destination box with phase status
// ════════════════════════════════════════════════════════════

extension _RiderTrackingPhaseIndicator on _RiderTrackingScreenState {

  // ── Phase-based status text (top label) ──
  String get _topStatusText {
    final s = S.of(context);
    switch (_phase) {
      case _TrackPhase.arriving:
        return s.driverEnRoute;
      case _TrackPhase.arrived:
        return s.driverHasArrived;
      case _TrackPhase.onTrip:
        return s.onWayToDestination;
      case _TrackPhase.nearDestination:
        return s.arrivingAtDestination;
      case _TrackPhase.completed:
        return s.onWayToDestination;
    }
  }

  // ── Phase-based bottom card text ──
  String get _bottomCardText {
    final s = S.of(context);
    switch (_phase) {
      case _TrackPhase.arriving:
        return s.driverOnTheWayCard;
      case _TrackPhase.arrived:
        return s.driverWaitingForYou;
      case _TrackPhase.onTrip:
        return s.onWayToDestinationCard;
      case _TrackPhase.nearDestination:
        return s.arrivingAtDestinationCard;
      case _TrackPhase.completed:
        return s.onWayToDestinationCard;
    }
  }

  // ── Phase-based dot color ──
  Color get _dotColor {
    switch (_phase) {
      case _TrackPhase.arriving:
        return const Color(0xFFFFD700); // Golden — driver en camino
      case _TrackPhase.arrived:
        return const Color(0xFF2196F3); // Blue — driver llegó al pickup
      case _TrackPhase.onTrip:
        return const Color(0xFFFFD700); // Golden — en camino al destino
      case _TrackPhase.nearDestination:
        return const Color(0xFFFFD700); // Golden — llegando
      case _TrackPhase.completed:
        return const Color(0xFFFFD700);
    }
  }

  // ── Destination + ETA box (floats at bottom) ──
  Widget _buildDestinationBox() {
    final bool isArrivedState = _phase == _TrackPhase.arrived;
    final String topText = _topStatusText;
    final String bottomText = _bottomCardText;
    final Color dotColor = _dotColor;

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
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Status label with phase-based dot color
                Row(
                  children: [
                    // Phase-based dot: pulsing on arrived, animated color transitions
                    if (isArrivedState)
                      ScaleTransition(
                        scale: Tween<double>(begin: 0.7, end: 1.3)
                            .animate(_arrivedDotPulse),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 500),
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: dotColor,
                          ),
                        ),
                      )
                    else
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
                // Bottom card text — changes per phase with smooth fade
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  transitionBuilder: (child, anim) =>
                      FadeTransition(opacity: anim, child: child),
                  child: Text(
                    bottomText,
                    key: ValueKey(bottomText),
                    style: TextStyle(
                      color: isArrivedState ? const Color(0xFFC8A951) : Colors.white,
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
          // ETA badge (hidden when arrived)
          if (!isArrivedState)
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
      ),
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
