part of '../../screens/rider_tracking_screen.dart';

// ════════════════════════════════════════════════════════════
//  DRIVER INFO CARD — driver details, avatar, plate
// ════════════════════════════════════════════════════════════

extension _RiderTrackingDriverInfoCard on _RiderTrackingScreenState {

  String get _vehicleAsset {
    final rn = widget.rideName.toLowerCase();
    final m = widget.vehicleModel.toLowerCase();
    if (rn.contains('vip') || rn.contains('suv') || rn.contains('suburban') || m.contains('suburban')) {
      return 'assets/images/car_suv.png';
    }
    if (rn.contains('sedan') || rn.contains('premium') || rn.contains('fusion') || m.contains('fusion')) {
      return 'assets/images/car_sedan.png';
    }
    return 'assets/images/car_economy.png';
  }

  Widget _driverInitial() => Container(
    color: const Color(0xFF1A1A1A),
    child: Center(
      child: Text(
        widget.driverName.isNotEmpty ? widget.driverName[0].toUpperCase() : 'D',
        style: const TextStyle(
          color: Color(0xFFD4AF37), fontSize: 18, fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );

  // ── Driver info card (floats at top) ──
  Widget _buildDriverCard() {
    final s = S.of(context);
    String statusLabel;
    switch (_phase) {
      case _TrackPhase.arriving:
        statusLabel = s.meetDriverAtPickup;
      case _TrackPhase.arrived:
        statusLabel = s.yourDriverArrivedExcl;
      case _TrackPhase.onTrip:
        statusLabel = s.onTripToDestination;
      case _TrackPhase.nearDestination:
        statusLabel = s.arrivingAtDestination;
      case _TrackPhase.completed:
        statusLabel = s.youHaveArrived;
    }

    final vehicleLabel = [
      widget.vehicleColor,
      widget.vehicleMake,
      widget.vehicleModel,
    ].where((v) => v.isNotEmpty).join(' ');

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Status label
          Row(
            children: [
              Container(
                width: 8, height: 8,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFFD4AF37),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  statusLabel,
                  style: const TextStyle(color: Color(0xFFD4AF37), fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.6),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Driver row
          Row(
            children: [
              // Driver photo with verified badge
              VerifiedAvatar(
                photoUrl: widget.driverPhotoUrl,
                radius: 22,
                fallbackName: widget.driverName,
                isVerified: true,
              ),
              const SizedBox(width: 10),
              // Name + rating
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.driverName,
                      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(Icons.star_rounded, color: Color(0xFFD4AF37), size: 14),
                        const SizedBox(width: 3),
                        Text(
                          widget.driverRating.toStringAsFixed(1),
                          style: const TextStyle(color: Colors.white60, fontSize: 13),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Plate + vehicle
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      widget.vehiclePlate.isNotEmpty
                          ? widget.vehiclePlate.toUpperCase()
                          : '---',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  if (vehicleLabel.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      vehicleLabel,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 10),
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Action row: chat + call + more
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.of(context).push(
                    slideFromRightRoute(
                      ChatScreen(
                        recipientName: widget.driverName.split(' ').first,
                        avatarInitial: widget.driverName.isNotEmpty
                            ? widget.driverName[0].toUpperCase()
                            : 'D',
                        tripId: widget.tripId,
                        currentRole: 'rider',
                      ),
                    ),
                  ),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF262626),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
                        ),
                        child: Text(
                          S.of(context).typeMessage,
                          style: const TextStyle(color: Colors.white30, fontSize: 13),
                        ),
                      ),
                      if (widget.tripId != null)
                        StreamBuilder<int>(
                          stream: ChatService().unreadCountStream(
                            rideId: widget.tripId.toString(),
                            readerRole: 'rider',
                          ),
                          builder: (context, snap) {
                            final count = snap.data ?? 0;
                            if (count == 0) return const SizedBox.shrink();
                            return Positioned(
                              right: -4, top: -4,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: const BoxDecoration(
                                  color: Color(0xFFEF4444),
                                  shape: BoxShape.circle,
                                ),
                                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                                child: Text(
                                  count > 9 ? '9+' : '$count',
                                  style: const TextStyle(
                                    color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _buildCardIconBtn(icon: Icons.phone_rounded, onTap: () {}),
              const SizedBox(width: 8),
              _buildCardIconBtn(
                icon: Icons.share_rounded,
                onTap: _handleShareTrip,
              ),
              const SizedBox(width: 8),
              _buildCardIconBtn(
                icon: Icons.more_horiz_rounded,
                onTap: _phase == _TrackPhase.onTrip
                    ? _showCancelOnTripDialog
                    : _showCancelDialog,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCardIconBtn({required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: const Color(0xFF262626),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Icon(icon, color: Colors.white60, size: 18),
      ),
    );
  }

  void _handleShareTrip() {
    final tripId = widget.firestoreTripId ?? widget.tripId?.toString() ?? 'unknown';
    final shareText = '''🚗 Sigue mi viaje en tiempo real

Mi conductor está en camino.
Puedes ver su ubicación aquí:
https://cruiseapp.com/track/$tripId

Powered by Cruise''';
    Share.share(
      shareText,
      subject: 'Seguimiento de viaje en tiempo real',
    );
  }

  Widget _buildBackButton(double topPad) {
    return Positioned(
      top: topPad + 10,
      left: 16,
      child: GestureDetector(
        onTap: _navigateToHome,
        child: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A).withValues(alpha: 0.9),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 12,
              ),
            ],
          ),
          child: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white, size: 18),
        ),
      ),
    );
  }
}
