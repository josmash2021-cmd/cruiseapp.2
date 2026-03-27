part of '../../screens/rider_tracking_screen.dart';

// ════════════════════════════════════════════════════════════
//  TRIP PHASE INDICATOR — destination box with phase status
// ════════════════════════════════════════════════════════════

extension _RiderTrackingPhaseIndicator on _RiderTrackingScreenState {

  // ── Destination + ETA box (floats at bottom) ──
  Widget _buildDestinationBox() {
    final s = S.of(context);
    final destAddr = _phase == _TrackPhase.onTrip || _phase == _TrackPhase.completed
        ? (widget.dropoffLabel.trim().isNotEmpty ? widget.dropoffLabel : s.destinationLabel)
        : (widget.pickupLabel.trim().isNotEmpty ? widget.pickupLabel : s.pickupLocation);
    final statusTag = _phase == _TrackPhase.arrived
        ? s.yourDriverArrivedExcl
        : (_phase == _TrackPhase.onTrip ? s.onTripToDestination : s.meetDriverAtPickup);

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
                Text(
                  statusTag,
                  style: const TextStyle(
                    color: Color(0xFFD4AF37),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  destAddr,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
